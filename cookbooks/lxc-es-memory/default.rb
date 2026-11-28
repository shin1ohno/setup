# frozen_string_literal: true

# es-memory — unified memory MCP (v2) backed by the ElasticSearch cluster
# (es-0/1/2). BM25 + dense_vector kNN hybrid search on the existing 3-node
# cluster (basic license, no ML — embeddings computed externally via Voyage).
#
# Runs as native systemd units + a Python venv (NOT docker). Per the PVE LXC
# design gate (~/.claude/docs/pve-lxc-detail.md): a single-purpose service LXC
# prefers apt+venv+systemd over docker-compose, avoiding the docker-in-LXC bug
# class (bind-mount UID mapping, .env shell-interpretation, BuildKit failures,
# image pulls). Two units share one venv:
#
#   memory-mcp-v2.service    uvicorn server:app  (127.0.0.1:8010)
#   memory-v2-proxy.service  proxy.py PATH_PREFIX=/memory  (:8767)
#
# The v1 Mem0-compatible stack (es-memory-mcp :8000 + es-memory-memory-proxy
# :8766, indices `knowledge` + `memory-user`) was RETIRED after two months of
# rollback standby — see the retire execute below. Its content had already been
# migrated into the v2 indices, so nothing reads it. What the v1 block owned
# and v2 still needs (the shared venv, its base wheels, the auth proxy source,
# the staging dirs) is retained below and relabelled as shared.

include_cookbook "awscli::linux"

# Pin the scoped fleet AWS profile (pve-bootstrap-ssm) so the auth gate and the
# .env generator target the same IAM principal — see CLAUDE.md "Auth-check gate
# must match the cookbook's actual invocation profile".
ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

base_dir = "/opt/es-memory"
venv_dir = "#{base_dir}/venv"

# Debian 13 minimal LXC ships without python3-venv/pip — see
# ~/.claude/docs/ruby-detail.md "Debian 13 Minimal LXC — Mandatory Bootstrap".
execute "install es-memory python deps" do
  command "apt-get update -qq && apt-get install -y python3 python3-venv python3-pip ca-certificates"
  not_if "dpkg -s python3-venv python3-pip >/dev/null 2>&1"
end

directory base_dir do
  owner "root"
  group "root"
  mode "755"
  action :create
end

# Restart executes (declared early so the file resources below can notify
# them). only_if guards the first converge, where the unit file is installed
# later in this same recipe by systemd_unit — restart is skipped until the
# unit exists, and systemd_unit's own activate starts it.
%w[memory-mcp-v2 memory-v2-proxy].each do |svc|
  execute "restart #{svc}" do
    command "sudo systemctl restart #{svc}.service"
    action :nothing
    only_if "systemctl cat #{svc}.service >/dev/null 2>&1"
  end
end

# Paths the placement below writes to; the resources further down use them too.
app_dir_v2        = "#{base_dir}/app-v2"
es_indices_v2_dir = "#{base_dir}/es-indices-v2"
keeper_dir        = "#{base_dir}/keeper"
units_staging     = "#{node[:setup][:root]}/es-memory"

# ai-memory comes from shin1ohno/ai-memory at the SHA in files/ai-memory.pin
# (ADR 0013). The checkout sits outside /root/setup, which mitamae-runner cleans
# every cycle, and outside /opt/es-memory/app*, which the v1 cleanup deletes.
ai_memory_checkout = "#{base_dir}/ai-memory-src"
ai_memory_marker   = "#{base_dir}/DEPLOYED_SHA"
ai_memory_pin = File.read(File.join(File.dirname(__FILE__), "files", "ai-memory.pin")).strip
raise "ai-memory.pin must be one 40-hex SHA" unless ai_memory_pin =~ /\A[0-9a-f]{40}\z/

# Compiled ai-memory binaries (ADR 0013 Decision 8, binary track). files/ai-memory-bin.pin
# is empty until the first release, and every resource of the track is declared only
# when it holds a pin, so an empty or missing file leaves this recipe as before.
#   source_sha=<40 hex, equal to ai-memory.pin>
#   <name> <64-hex sha256>        one line per asset of release bin-<source_sha>
# Each name must be listed here with the unit that runs it from bin/current/<name>;
# the unit file comes from the ai-memory checkout's systemd/ directory.
ai_memory_bin_units = {
  "ai-memory-noop" => "ai-memory-noop.service",
}
ai_memory_bin_script = "#{base_dir}/ai-memory-bin.sh"
ai_memory_bins = {}
ai_memory_bin_pin_path = File.join(File.dirname(__FILE__), "files", "ai-memory-bin.pin")
ai_memory_bin_lines = File.exist?(ai_memory_bin_pin_path) ? File.read(ai_memory_bin_pin_path).split("\n").map(&:strip).reject(&:empty?) : []
unless ai_memory_bin_lines.empty?
  source_line = /\Asource_sha=([0-9a-f]{40})\z/.match(ai_memory_bin_lines.shift)
  raise "ai-memory-bin.pin must start with source_sha=<40 hex>" unless source_line
  raise "ai-memory-bin.pin source_sha must equal ai-memory.pin (#{ai_memory_pin})" unless source_line[1] == ai_memory_pin
  ai_memory_bin_lines.each do |line|
    asset = /\A(ai-memory-[a-z-]+) ([0-9a-f]{64})\z/.match(line)
    raise "ai-memory-bin.pin line is not '<name> <64-hex sha256>': #{line}" unless asset
    raise "ai-memory-bin.pin lists #{asset[1]} twice" if ai_memory_bins.key?(asset[1])
    raise "ai-memory-bin.pin lists #{asset[1]}, which has no unit in this recipe" unless ai_memory_bin_units.key?(asset[1])
    ai_memory_bins[asset[1]] = asset[2]
  end
  raise "ai-memory-bin.pin lists no binary" if ai_memory_bins.empty?
end
ai_memory_bin_assets = ai_memory_bins.map { |name, sha| "#{name}=#{sha}" }.join(" ")
ai_memory_bin_restart = ai_memory_bins.keys.map { |name| "#{ai_memory_bin_units[name]}=#{name}" }.join(" ")

staged_user  = node[:setup][:user]
staged_group = node[:setup][:group]
ai_memory_placements = [
  ["requirements.lock",           "#{base_dir}/requirements.lock",    "644", "root", "root"],
  ["requirements.txt",            "#{base_dir}/requirements.txt",     "644", "root", "root"],
  ["requirements-v2.txt",         "#{app_dir_v2}/requirements-v2.txt", "644", "root", "root"],
  ["auth-proxy/proxy.py",         "#{app_dir_v2}/proxy.py",           "644", "root", "root"],
  ["memory-keeper-health.sh",     "#{units_staging}/memory-keeper-health.sh", "755", staged_user, staged_group],
]
# memory-session{,-message}.json: the session search indices (design spec §7.1).
# setup_indices_v2.sh skips them with a WARN when they are not deployed.
%w[
  memory-fact.json memory-knowledge.json memory-episode.json memory-stats.json
  memory-session.json memory-session-message.json setup_indices_v2.sh
].each do |f|
  ai_memory_placements << ["es-indices-v2/#{f}", "#{es_indices_v2_dir}/#{f}", f.end_with?(".sh") ? "755" : "644", "root", "root"]
end
%w[
  memory-mcp-v2.service memory-v2-proxy.service
  memory-keeper-health.service memory-keeper-health.timer
  memory-session-maint.service memory-session-maint.timer
  memory-keeper-reconcile.service memory-keeper-reconcile.timer
  memory-consolidate.service memory-consolidate.timer
].each do |unit|
  ai_memory_placements << ["systemd/#{unit}", "#{units_staging}/#{unit}", "644", staged_user, staged_group]
end
ai_memory_bins.each_key do |name|
  unit = ai_memory_bin_units[name]
  ai_memory_placements << ["systemd/#{unit}", "#{units_staging}/#{unit}", "644", staged_user, staged_group]
end
ai_memory_place_lines = ai_memory_placements.map { |src, dest, mode, own, grp| "place #{src} #{dest} #{mode} #{own} #{grp}" }.join("\n")

# Binaries are staged BEFORE the source placement: the placement writes DEPLOYED_SHA
# and its notify fires only when it runs, so a binary failure after it would make the
# next converge skip the placement and lose the restart. Failing here stops the
# converge with DEPLOYED_SHA, current and the running units unchanged.
unless ai_memory_bins.empty?
  remote_file ai_memory_bin_script do
    source "files/ai-memory-bin.sh"
    owner "root"
    group "root"
    mode "755"
  end

  execute "stage ai-memory binaries" do
    command "/bin/bash #{ai_memory_bin_script} stage #{ai_memory_pin} #{base_dir} #{ai_memory_bin_assets}"
    not_if "/bin/bash #{ai_memory_bin_script} check-staged #{ai_memory_pin} #{base_dir} #{ai_memory_bin_assets}"
  end
end

# One execute, evaluated at converge time: nothing in the checkout is read while
# the recipe compiles. The global and system git config are ignored so a host's
# url rewrite cannot move this fetch onto SSH or a key. Each placed file must hash
# to the pinned blob, and the marker is written last, so a partial run repeats.
execute "place ai-memory at the pinned SHA" do
  command <<~SH
    set -eu
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
    umask 022
    PIN=#{ai_memory_pin}
    CO=#{ai_memory_checkout}
    mkdir -p "$CO"
    [ -d "$CO/.git" ] || git -C "$CO" init -q
    git -C "$CO" config remote.origin.url https://github.com/shin1ohno/ai-memory.git
    git -C "$CO" fetch -q --filter=blob:none origin +refs/heads/main:refs/remotes/origin/main
    git -C "$CO" merge-base --is-ancestor "$PIN" refs/remotes/origin/main
    mkdir -p "$CO/.git/info"
    echo '* -text -eol -ident -filter -working-tree-encoding' > "$CO/.git/info/attributes"
    git -C "$CO" -c advice.detachedHead=false checkout -q --force --detach "$PIN"
    [ "$(git -C "$CO" rev-parse HEAD)" = "$PIN" ]

    place() {
      mkdir -p "$(dirname "$2")"
      install -m "$3" -o "$4" -g "$5" "$CO/$1" "$2"
      want=$(git -C "$CO" ls-tree HEAD -- "$1" | cut -f1 | cut -d' ' -f3)
      got=$(git hash-object --no-filters "$2")
      [ -n "$want" ] && [ "$want" = "$got" ]
    }
    manifest() {
      sed 's/\\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//' "$CO/$1/MANIFEST" | grep -vE '^(#|$)'
    }

    # A failed substitution in a for list does not trip set -e, and an empty
    # list would write the marker with no runtime files placed.
    [ -n "$(manifest memory-mcp)" ]
    [ -n "$(manifest memory-keeper)" ]

    #{ai_memory_place_lines}
    for f in $(manifest memory-mcp); do place "memory-mcp/$f" "#{app_dir_v2}/$f" 644 root root; done
    for f in $(manifest memory-keeper); do place "memory-keeper/$f" "#{keeper_dir}/$f" 644 root root; done

    echo "$PIN" > #{ai_memory_marker}.tmp
    mv #{ai_memory_marker}.tmp #{ai_memory_marker}
  SH
  # The marker alone would leave a lost staged unit missing, and the resources
  # below fail on it. Content drift under a matching marker is not detected.
  not_if (["test \"$(cat #{ai_memory_marker} 2>/dev/null)\" = #{ai_memory_pin}"] +
          ai_memory_placements.map { |_, dest, _, _, _| "test -f #{dest}" }).join(" && ")
  notifies :run, "execute[restart memory-mcp-v2]"
  notifies :run, "execute[restart memory-v2-proxy]"
end

# The guard compares the link with the pin, not DEPLOYED_SHA, so a converge that
# stopped between the placement and this switch finishes it next time.
unless ai_memory_bins.empty?
  execute "activate ai-memory binaries" do
    command "/bin/bash #{ai_memory_bin_script} activate #{ai_memory_pin} #{base_dir}"
    not_if "/bin/bash #{ai_memory_bin_script} check-active #{ai_memory_pin} #{base_dir}"
  end
end

# Shared venv base requirements ---------------------------------------------
# LOAD-BEARING for v2, despite the "v1" ancestry: requirements-v2.txt
# deliberately omits aiohttp / PyJWT / opentelemetry ("those live in the proxy
# venv"), and there is only ONE venv. These are the wheels memory-v2-proxy runs
# on, so this install stays and now notifies the v2 units instead of the
# retired v1 ones. Moved app/ -> base_dir with the v1 app dir; the .reqs.md5
# sentinel embeds the old path, so the first converge reinstalls once and
# rewrites it.
execute "create es-memory venv" do
  command "python3 -m venv #{venv_dir}"
  not_if "test -x #{venv_dir}/bin/python"
end

# The host has one shared venv. Exact pins and hashes must be installed once;
# a second floor-based install would undo the lock and its rollback behavior.
execute "pip install es-memory deps" do
  command "#{venv_dir}/bin/pip install --require-hashes -r #{base_dir}/requirements.lock && " \
          "#{venv_dir}/bin/pip check && " \
          "sha256sum #{base_dir}/requirements.lock > #{venv_dir}/.reqs-lock.sha256"
  not_if "test -x #{venv_dir}/bin/uvicorn && test -f #{venv_dir}/.reqs-lock.sha256 && " \
         "sha256sum -c --status #{venv_dir}/.reqs-lock.sha256 && #{venv_dir}/bin/pip check >/dev/null 2>&1"
  notifies :run, "execute[restart memory-mcp-v2]"
  notifies :run, "execute[restart memory-v2-proxy]"
end

# Staging dir for SSM-generated .env files (shared: the v2 generator below
# writes into it).
generated_dir = "#{node[:setup][:root]}/generated"
directory node[:setup][:root] do
  mode "755"
end
directory generated_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

# systemd units -------------------------------------------------------------
directory units_staging do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

# Retire the v1 /cognee proxy: the cognee MCP namespace was removed from
# server.py, so es-memory-cognee-proxy is no longer staged above. Cookbook
# file removal does NOT stop an already-running unit — disable + remove it
# explicitly (idempotent: fires only while the unit still exists on the host).
execute "retire es-memory-cognee-proxy" do
  command "systemctl disable --now es-memory-cognee-proxy.service && " \
          "rm -f /etc/systemd/system/es-memory-cognee-proxy.service && " \
          "systemctl daemon-reload"
  only_if "systemctl cat es-memory-cognee-proxy.service >/dev/null 2>&1"
end

# Retire the v1 Mem0 stack (same shape as the cognee proxy above): the units
# are no longer staged, and removing a cookbook file does NOT stop a running
# unit. Idempotent — each fires only while its unit still exists on the host.
# The ES indices these served (`knowledge`, `memory-user`) are dropped by a
# separate operator step, after a snapshot.
%w[es-memory-mcp es-memory-memory-proxy].each do |svc|
  execute "retire #{svc}" do
    command "systemctl disable --now #{svc}.service && " \
            "rm -f /etc/systemd/system/#{svc}.service && " \
            "systemctl daemon-reload"
    only_if "systemctl cat #{svc}.service >/dev/null 2>&1"
  end
end

# v1 on-disk leftovers. The venv, base requirements and generated/ staging dir
# are deliberately NOT here — v2 runs on them.
%w[/opt/es-memory/app /opt/es-memory/es-indices].each do |d|
  execute "remove v1 leftover #{d}" do
    command "rm -rf #{d}"
    only_if "test -d #{d}"
  end
end

file "/opt/es-memory/es-memory.env" do
  action :delete
  only_if "test -f /opt/es-memory/es-memory.env"
end

# ==========================================================================
# v2 (Voyage-embedding unified memory) — the only serving stack since the v1
# retirement above.
#
# The v2 units (memory-mcp-v2 + memory-v2-proxy) run from /opt/es-memory/app-v2
# and share the venv (/opt/es-memory/venv) with requirements-v2.txt installed
# into it ON TOP of the base requirements above — requirements-v2.txt alone is
# NOT a complete environment for memory-v2-proxy.
# ==========================================================================

env_path_v2 = "#{base_dir}/memory-v2.env"

directory app_dir_v2 do
  owner "root"
  group "root"
  mode "755"
  action :create
end



# Standalone v2 ES index templates + setup script (the server self-bootstraps
# indices via ensure_indices on startup; kept for manual ops / migration).
directory es_indices_v2_dir do
  owner "root"
  group "root"
  mode "755"
  action :create
end

# v2 .env (EnvironmentFile) from SSM. SECOND require_external_auth block, gated
# on the /memory/voyage-api-key param (the scoped fleet profile). The
# skip_if is CONTENT-AWARE (grep VOYAGE_API_KEY), not File.exist? — per
# ~/ManagedProjects/setup/.claude/rules/ruby.md the file-existence form makes a generator key change a
# silent no-op on a host whose .env predates it.
generate_env_v2_script = "#{ai_memory_checkout}/generate_env_v2.sh"
env_v2_temp_path = "#{generated_dir}/memory-v2.env"

# Session search archive writer (design spec §6.5 Storage personal, §10). Its
# keys live under /es-memory-ct119/session-archive/*, readable ONLY by the
# es-memory-ct119-bootstrap profile, which the operator places on this CT once
# (bin/bootstrap-lxc-creds --profile es-memory-ct119-bootstrap) — never by
# pve-bootstrap-ssm, which the whole fleet shares. Optional: when the profile or
# the parameters are absent this gate skips with a WARN, the generator below
# leaves SESSION_ARCHIVE_* out, and the server answers archive:"skipped" while
# everything else works. The gate reads with the same --profile as the
# generator (check_command decrypts but prints only the name).
session_archive_profile = "es-memory-ct119-bootstrap"
session_archive_ok = false
require_external_auth(
  tool_name: "AWS CLI (profile=#{session_archive_profile}) for /es-memory-ct119/session-archive/* (session search archive, optional)",
  check_command: "aws ssm get-parameter --name /es-memory-ct119/session-archive/secret-access-key " \
                 "--with-decryption --query Parameter.Name --output text " \
                 "--profile #{session_archive_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Place the '#{session_archive_profile}' profile on this CT " \
                "(bin/bootstrap-lxc-creds --profile #{session_archive_profile} --stdin <CT_ID>, keys from " \
                "/home-monitor/iam/#{session_archive_profile}/* via the admin profile), then press Enter. " \
                "Press s to continue without the session archive.",
) do
  session_archive_ok = true
end

# Content-aware: the env must carry the session-search keys, and the archive
# keys whenever the archive gate above passed (so placing the profile later
# regenerates the env on the next apply).
env_v2_complete = lambda do
  body = File.exist?(env_path_v2) ? File.read(env_path_v2) : ""
  body.include?("VOYAGE_API_KEY") && body.include?("SESSION_SCOPE_POLICY") &&
    (!session_archive_ok || body.include?("SESSION_ARCHIVE_BUCKET"))
end

require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /monitoring/elastic/* + /memory/voyage-api-key SSM params",
  check_command: "aws ssm get-parameter --name /memory/voyage-api-key " \
                 "--profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on " \
                "/monitoring/elastic/* and /memory/voyage-api-key in #{aws_region}. " \
                "On a fresh machine: aws configure --profile #{aws_profile}. " \
                "Then press Enter.",
  skip_if: env_v2_complete,
) do
  execute "generate memory-v2 .env" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "SESSION_ARCHIVE_PROFILE=#{session_archive_ok ? session_archive_profile : ''} " \
            "bash #{generate_env_v2_script} #{env_v2_temp_path}"
    user node[:setup][:user]
  end
end

# Place the v2 env (converge-time only_if, not compile-time File.exist? — see
# ~/ManagedProjects/setup/.claude/rules/ruby.md mitamae evaluation model).
# sensitive: the env carries the ES credentials and the embedding API key, and
# mitamae otherwise prints the INFO-level file diff into the auto-mitamae
# runner's log (check 15).
remote_file env_path_v2 do
  source env_v2_temp_path
  owner "root"
  group "root"
  mode "600"
  sensitive true
  notifies :run, "execute[restart memory-mcp-v2]"
  notifies :run, "execute[restart memory-v2-proxy]"
  only_if "test -f #{env_v2_temp_path}"
end

file env_v2_temp_path do
  action :delete
  only_if "test -f #{env_v2_temp_path}"
end

# Proxy shared secret (design spec §6.5 Gate): the proxy sends it as
# X-Proxy-Secret and the server refuses identity headers without it, so a local
# process cannot reach 127.0.0.1:8010 and forge X-Verified-*. 32 random bytes,
# generated ONCE on this box into a root-only file that both units read as an
# EnvironmentFile — never regenerated while the file is non-empty, never in SSM,
# never printed (python3 writes it under umask 077; nothing reaches stdout).
proxy_secret_env = "#{base_dir}/proxy-secret.env"
execute "generate memory-v2 proxy shared secret" do
  command <<~SH
    set -e
    umask 077
    python3 -c 'import secrets; print("PROXY_SHARED_SECRET=" + secrets.token_hex(32))' > #{proxy_secret_env}.tmp
    mv #{proxy_secret_env}.tmp #{proxy_secret_env}
  SH
  not_if "test -s #{proxy_secret_env}"
  notifies :run, "execute[restart memory-mcp-v2]"
  notifies :run, "execute[restart memory-v2-proxy]"
end

# Proxy allow-list from SSM --------------------------------------------------
# memory-v2-proxy admits a human (authorization_code) token only when its sub is in
# ALLOWED_SUBS, checked on every request, and such a caller can read, write, forget
# and revise anything in the store (claude.ai tokens carry no audience, so this list
# is the only resource-level gate). The unit pinned from ai-memory lists the operator
# alone inline. Further subjects come from a DEDICATED SSM parameter,
# /memory/proxy-allowed-subs — never the OAuth consent list, which admits people to
# other gateway services too — through a root-only EnvironmentFile that a drop-in adds
# to the unit. A file line overrides the unit's inline ALLOWED_SUBS:
#   file present -> the list is the operator (the floor below) + the parameter; an
#                   address removed from the parameter drops out at the next converge.
#   no file      -> the unit's inline list, the operator alone, applies (fetch failed,
#                   the value failed validation, or the parameter does not exist yet):
#                   every extra subject is locked out until the file is back.
# The generator validates the value because it becomes an EnvironmentFile (a newline or
# quote could override another proxy variable). The proxy reads the list at import, so a
# changed file restarts it. A parameter edit takes effect at the next converge
# (reconcile interval 3600 s + jitter up to 3600 s).
proxy_operator_sub         = "shin1ohno@gmail.com"
proxy_allowed_subs_script  = "#{units_staging}/generate-proxy-allowed-subs.sh"
proxy_allowed_subs_tmp     = "#{generated_dir}/proxy-allowed-subs.env"
proxy_allowed_subs_env     = "#{base_dir}/proxy-allowed-subs.env"
proxy_allowed_subs_dropdir = "/etc/systemd/system/memory-v2-proxy.service.d"

# ONE execute, notified by both resources below. Mitamae runs delayed notifications in
# the order resources change and drops a repeated one, so two separate "daemon-reload"
# and "restart" executes could restart the proxy BEFORE it has seen the drop-in.
execute "reload systemd and restart memory-v2-proxy" do
  command "sudo systemctl daemon-reload && sudo systemctl restart memory-v2-proxy.service"
  action :nothing
  only_if "systemctl cat memory-v2-proxy.service >/dev/null 2>&1"
end

remote_file proxy_allowed_subs_script do
  source "files/generate-proxy-allowed-subs.sh"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# A temp file left by an earlier run must not be placed when this run's generator
# rejects the value, so clear it first.
file proxy_allowed_subs_tmp do
  action :delete
end

# The check reads the real parameter with the generator's profile and prints only its
# name, never the decrypted value. Without the parameter (not created yet) the gate
# fails and the block is skipped, so the unit's inline list stays in force.
require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /memory/proxy-allowed-subs (memory proxy allow-list, optional)",
  check_command: "aws ssm get-parameter --name /memory/proxy-allowed-subs --with-decryption " \
                 "--query Parameter.Name --output text " \
                 "--profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Create the parameter as the admin profile (docs/mcp-deployment.md \"The memory proxy " \
                "allow-list\"), or press s to continue without it; the unit's inline ALLOWED_SUBS then applies.",
) do
  execute "generate memory-v2 proxy allowed-subs env" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "bash #{proxy_allowed_subs_script} #{proxy_allowed_subs_tmp} #{proxy_operator_sub}"
    user node[:setup][:user]
  end
end

# remote_file compares content, so an unchanged list neither rewrites the file nor
# restarts the proxy. The temp file is validated again here (exactly one line of
# ALLOWED_SUBS=<emails>) so a file that did not come from the generator is never placed.
# sensitive: the file carries the allowed addresses, and mitamae would otherwise print
# the diff into the runner log (check 15).
remote_file proxy_allowed_subs_env do
  source proxy_allowed_subs_tmp
  owner "root"
  group "root"
  mode "600"
  sensitive true
  notifies :run, "execute[reload systemd and restart memory-v2-proxy]"
  only_if "test -f #{proxy_allowed_subs_tmp} && bash #{proxy_allowed_subs_script} --check #{proxy_allowed_subs_tmp}"
end

file proxy_allowed_subs_tmp do
  action :delete
  only_if "test -f #{proxy_allowed_subs_tmp}"
end

directory proxy_allowed_subs_dropdir do
  owner "root"
  group "root"
  mode "755"
  action :create
end

# The drop-in only names the file. EnvironmentFile= entries accumulate across unit and
# drop-in (proxy-secret.env stays), so it must never contain an empty EnvironmentFile=,
# which would reset the list. The leading "-" makes the file optional.
file "#{proxy_allowed_subs_dropdir}/allowed-subs.conf" do
  content "[Service]\nEnvironmentFile=-#{proxy_allowed_subs_env}\n"
  owner "root"
  group "root"
  mode "644"
  notifies :run, "execute[reload systemd and restart memory-v2-proxy]"
end

# Persistent logs for both v2 services -------------------------------------
# lxc-core masks journald in every LXC (lxc-mask-unsupported-units), and the PVE host
# does not capture container output either (`journalctl --machine=119` fails), so the
# units' StandardOutput=journal ends at /dev/null and no line survives. A drop-in points
# stdout at an append-only file instead; StandardError=inherit puts stderr (logging,
# the print(..., file=sys.stderr) AUDIT lines, uvicorn) in the same file. The ai-memory
# unit files stay untouched: they are human-only paths in that repository.
#   append:, not file: -- file: truncates on every start, which loses the lines that
#   explain a crash loop. systemd opens the file as PID 1 with O_APPEND.
#   0600 in a 0700 directory -- the lines carry subjects (email addresses), request
#   paths and audit records. systemd creates a missing append: target 0644, so the
#   files are created here first; systemd and logrotate's copytruncate keep the mode.
# Reading (root in the CT): tail -F /var/log/es-memory/memory-v2-proxy.log
es_memory_log_dir = "/var/log/es-memory"
mcp_v2_dropdir    = "/etc/systemd/system/memory-mcp-v2.service.d"

# Same shape as the proxy's reload+restart above: a changed drop-in needs daemon-reload
# BEFORE the restart, and one execute keeps the two in that order.
execute "reload systemd and restart memory-mcp-v2" do
  command "sudo systemctl daemon-reload && sudo systemctl restart memory-mcp-v2.service"
  action :nothing
  only_if "systemctl cat memory-mcp-v2.service >/dev/null 2>&1"
end

directory es_memory_log_dir do
  owner "root"
  group "root"
  mode "700"
  action :create
end

directory mcp_v2_dropdir do
  owner "root"
  group "root"
  mode "755"
  action :create
end

{
  "memory-mcp-v2"   => mcp_v2_dropdir,
  "memory-v2-proxy" => proxy_allowed_subs_dropdir,
}.each do |svc, dropdir|
  log_file = "#{es_memory_log_dir}/#{svc}.log"

  execute "create #{log_file}" do
    command "install -m 600 -o root -g root /dev/null #{log_file}"
    not_if "test -f #{log_file}"
  end

  # A file systemd created before this block existed (0644) is tightened in place.
  execute "restrict #{log_file} to root" do
    command "chown root:root #{log_file} && chmod 600 #{log_file}"
    not_if "test \"$(stat -c '%U:%G %a' #{log_file})\" = 'root:root 600'"
  end

  file "#{dropdir}/50-log-file.conf" do
    content "[Service]\nStandardOutput=append:#{log_file}\nStandardError=inherit\n"
    owner "root"
    group "root"
    mode "644"
    notifies :run, "execute[reload systemd and restart #{svc}]"
  end
end

# copytruncate because the fd belongs to PID 1 and neither service can reopen its log;
# the few lines written between the copy and the truncate are lost. Bound: 14 days plus
# the live file, about 150 MB at the worst-case proxy rate.
remote_file "/etc/logrotate.d/es-memory" do
  source "files/logrotate-es-memory"
  owner "root"
  group "root"
  mode "644"
end

# v2 systemd units (units_staging is declared above).
%w[memory-mcp-v2 memory-v2-proxy].each do |svc|
  staged = "#{units_staging}/#{svc}.service"

  systemd_unit "#{svc}.service" do
    staging_path staged
  end
end

# Units that run a compiled binary from bin/current. systemd_unit restarts a unit
# only when its file changes; a new binary under an unchanged unit is picked up by
# the execute after it, which compares the running executable with current.
ai_memory_bins.each_key do |name|
  unit = ai_memory_bin_units[name]
  systemd_unit unit do
    staging_path "#{units_staging}/#{unit}"
  end
end

unless ai_memory_bins.empty?
  execute "restart units running a stale ai-memory binary" do
    command "/bin/bash #{ai_memory_bin_script} restart-stale #{base_dir} #{ai_memory_bin_restart}"
    only_if "/bin/bash #{ai_memory_bin_script} stale #{base_dir} #{ai_memory_bin_restart}"
  end
end

# === memory-keeper reconcile-loop health node_exporter textfile metric ===
#
# Clones the lxc-elasticsearch es-cluster-health textfile+timer pattern. The
# probe reads ES creds from memory-v2.env and writes memory_keeper_raw_backlog
# + memory_keeper_stats_age_seconds so Prometheus (already scraping this LXC on
# :9100) can alert on a stalled keeper loop on mini.
keeper_health_script_staging = "#{units_staging}/memory-keeper-health.sh"
keeper_health_script_path    = "/usr/local/bin/memory-keeper-health.sh"

# Defensive: node-exporter (lxc-core) creates the textfile dir, but declare it
# here too so include order is irrelevant (the script also mkdir -p's it).
execute "create /var/lib/node_exporter/textfile for memory-keeper-health" do
  command "install -d -m 0755 -o root -g root /var/lib/node_exporter/textfile"
  not_if "test -d /var/lib/node_exporter/textfile"
end

execute "install memory-keeper-health.sh to /usr/local/bin" do
  command "install -m 0755 -o root -g root #{keeper_health_script_staging} #{keeper_health_script_path}"
  not_if "test -f #{keeper_health_script_path} && " \
         "diff -q #{keeper_health_script_staging} #{keeper_health_script_path} 2>/dev/null"
end

# oneshot service (start false — driven solely by the timer) + timer, both via
# the systemd_unit helper. The .timer's activate is the 4-step reload + enable +
# restart-timer + start-companion-service sequence; the ensure-active fallback
# below covers the fresh-host case where staged == installed on first apply so
# the activate execute's diff-q notify never fires.
keeper_health_svc_staged = "#{units_staging}/memory-keeper-health.service"
systemd_unit "memory-keeper-health.service" do
  staging_path keeper_health_svc_staged
  start false
end

keeper_health_timer_staged = "#{units_staging}/memory-keeper-health.timer"
systemd_unit "memory-keeper-health.timer" do
  staging_path keeper_health_timer_staged
end

execute "ensure memory-keeper-health.timer active" do
  command "systemctl daemon-reload && systemctl enable --now memory-keeper-health.timer"
  not_if "systemctl is-active memory-keeper-health.timer >/dev/null 2>&1"
end

# === session search C8 maintenance (design spec §6.9) ===
#
# Daily oneshot: 365-day retention, purge-marker sweep, pending-embedding retry,
# re-mask after a ruleset upgrade, and the memory-stats run record /status
# reads. Runs app-v2/sessions_maint.py (deployed by the MANIFEST loop above)
# from the shared venv with the server's own env file. Same service + timer +
# ensure-active shape as memory-keeper-health above.
session_maint_svc_staged = "#{units_staging}/memory-session-maint.service"
systemd_unit "memory-session-maint.service" do
  staging_path session_maint_svc_staged
  start false
end

session_maint_timer_staged = "#{units_staging}/memory-session-maint.timer"
systemd_unit "memory-session-maint.timer" do
  staging_path session_maint_timer_staged
end

execute "ensure memory-session-maint.timer active" do
  command "systemctl daemon-reload && systemctl enable --now memory-session-maint.timer"
  not_if "systemctl is-active memory-session-maint.timer >/dev/null 2>&1"
end

# ==========================================================================
# v2 write-intelligence keeper (reconcile + nightly consolidate) — ON THIS CT.
#
# The v2 server has NO LLM; fact reconciliation (ADD/UPDATE/NOOP) + nightly
# consolidation run `claude -p` on the Claude subscription. Consolidated here
# onto es-memory (was mini/launchd) per the 2026-07-04 decision — removes the
# cross-host dependency. The keeper python (files/memory-keeper/) is REUSED
# VERBATIM from the mini worker: stdlib-only (urllib, /usr/bin/python3), every
# path __file__-relative or env-driven. Auth is a one-time operator step
# (`claude setup-token` on this CT); the timers stay stopped until it succeeds.
# ==========================================================================
claude_bin = "/root/.local/bin/claude"

# claude CLI (standalone binary — no node). Idempotent; on an already-installed
# host the not_if skips the network fetch.
execute "install claude CLI for memory-keeper" do
  command "curl -fsSL https://claude.ai/install.sh | bash"
  not_if "test -x #{claude_bin}"
end

directory keeper_dir do
  owner "root"
  group "root"
  mode "755"
  action :create
end

directory "#{keeper_dir}/prompts" do
  owner "root"
  group "root"
  mode "755"
  action :create
end

# systemd units: 2 oneshot services + 2 timers. Services are driven solely by
# their timers (a timer's Unit= starts its service without the service being
# `enable`d), so they are only INSTALLED here — nothing fires at boot. NOT via
# the systemd_unit helper: its .timer branch auto-enables + starts the companion
# service, which would fire reconcile/consolidate before `claude setup-token`.
%w[
  memory-keeper-reconcile.service memory-keeper-reconcile.timer
  memory-consolidate.service memory-consolidate.timer
].each do |unit|
  staged = "#{units_staging}/#{unit}"

  execute "install #{unit}" do
    command "cp #{staged} /etc/systemd/system/#{unit} && systemctl daemon-reload"
    not_if "test -f /etc/systemd/system/#{unit} && " \
           "diff -q #{staged} /etc/systemd/system/#{unit} >/dev/null 2>&1"
  end
end

# Token-presence gate: enable + start the timers only once the operator has run
# `claude setup-token` on this ct and written the token to keeper-claude.env
# (mode 600). `claude auth status` is NOT usable as the gate — setup-token mints
# a long-lived token consumed via CLAUDE_CODE_OAUTH_TOKEN (env, loaded by the
# unit's second EnvironmentFile), so `auth status` still reports loggedIn:false.
# Before the token file exists the units are installed but idle.
keeper_token_env = "#{base_dir}/keeper-claude.env"
%w[memory-keeper-reconcile.timer memory-consolidate.timer].each do |tmr|
  execute "ensure #{tmr} active" do
    command "systemctl enable --now #{tmr}"
    only_if "test -s #{keeper_token_env}"
    not_if "systemctl is-active #{tmr} >/dev/null 2>&1"
  end
end
