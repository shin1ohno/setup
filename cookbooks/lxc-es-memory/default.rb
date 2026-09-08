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

# Shared venv base requirements ---------------------------------------------
# LOAD-BEARING for v2, despite the "v1" ancestry: requirements-v2.txt
# deliberately omits aiohttp / PyJWT / opentelemetry ("those live in the proxy
# venv"), and there is only ONE venv. These are the wheels memory-v2-proxy runs
# on, so this install stays and now notifies the v2 units instead of the
# retired v1 ones. Moved app/ -> base_dir with the v1 app dir; the .reqs.md5
# sentinel embeds the old path, so the first converge reinstalls once and
# rewrites it.
remote_file "#{base_dir}/requirements.txt" do
  source "files/requirements.txt"
  owner "root"
  group "root"
  mode "644"
end

execute "create es-memory venv" do
  command "python3 -m venv #{venv_dir}"
  not_if "test -x #{venv_dir}/bin/python"
end

# Self-healing pip install: runs when the venv lacks the installed deps
# (uvicorn absent) OR requirements.txt changed since the last install (md5
# sentinel). NOT `action :nothing` — a notification-only install silently
# never runs on a re-apply where the venv dir exists but packages are missing
# (e.g. a prior interrupted install), leaving the units in an activating loop.
# The not_if guard makes it idempotent AND self-repairing.
execute "pip install es-memory deps" do
  command "#{venv_dir}/bin/pip install --upgrade pip && " \
          "#{venv_dir}/bin/pip install -r #{base_dir}/requirements.txt && " \
          "md5sum #{base_dir}/requirements.txt > #{venv_dir}/.reqs.md5"
  not_if "test -x #{venv_dir}/bin/uvicorn && test -f #{venv_dir}/.reqs.md5 && " \
         "md5sum -c --status #{venv_dir}/.reqs.md5"
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
units_staging = "#{node[:setup][:root]}/es-memory"
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

app_dir_v2  = "#{base_dir}/app-v2"
env_path_v2 = "#{base_dir}/memory-v2.env"

directory app_dir_v2 do
  owner "root"
  group "root"
  mode "755"
  action :create
end

# v2 requirements installed into the SAME venv. A SEPARATE md5 sentinel
# (.reqs-v2.md5) so a v2-only dependency bump reinstalls without touching the
# base sentinel — the "pip install es-memory deps" execute above stays intact.
# md5-only guard (no binary probe): the v2 wheels land in the shared venv
# already populated by the base install above.
remote_file "#{app_dir_v2}/requirements-v2.txt" do
  source "files/requirements-v2.txt"
  owner "root"
  group "root"
  mode "644"
end

execute "pip install memory v2 deps" do
  command "#{venv_dir}/bin/pip install -r #{app_dir_v2}/requirements-v2.txt && " \
          "md5sum #{app_dir_v2}/requirements-v2.txt > #{venv_dir}/.reqs-v2.md5"
  not_if "test -f #{venv_dir}/.reqs-v2.md5 && " \
         "md5sum -c --status #{venv_dir}/.reqs-v2.md5"
  notifies :run, "execute[restart memory-mcp-v2]"
  notifies :run, "execute[restart memory-v2-proxy]"
end

# v2 application code: every runtime file listed in files/memory-mcp/MANIFEST
# + the auth proxy. The MANIFEST is the single distribution unit (ADR 0010):
# bin/check-memory-v2-manifest fails CI when a non-test file in that directory
# is not listed, so a new module can no longer be committed without being
# deployed (the #895 merge_rules.py → ModuleNotFoundError class).
# proxy.py (files/auth-proxy/proxy.py) was shared with the retired v1 stack; the v2
# enforcement matrix is env-gated (MEMORY_AUDIENCES) so one file serves both
# namespaces.
# File.read + split, NOT File.readlines: mruby (the mitamae runtime) has no
# File.readlines and aborts the compile with NoMethodError — caught by the
# ADR 0010 design review against mitamae v1.14.0 (~/ManagedProjects/setup/.claude/rules/ruby.md
# "mruby API constraints"). The MANIFEST is a committed source asset, so a
# compile-time read is the right phase (unlike the `File.exist?`-on-generated-
# file anti-pattern).
memory_v2_manifest = ->(unit) {
  File.read(File.join(File.dirname(__FILE__), "files", unit, "MANIFEST")).split("\n")
      .map(&:strip).reject { |l| l.empty? || l.start_with?("#") }
}
memory_v2_manifest.call("memory-mcp").each do |mod|
  remote_file "#{app_dir_v2}/#{mod}" do
    source "files/memory-mcp/#{mod}"
    owner "root"
    group "root"
    mode "644"
    notifies :run, "execute[restart memory-mcp-v2]"
  end
end

remote_file "#{app_dir_v2}/proxy.py" do
  source "files/auth-proxy/proxy.py"
  owner "root"
  group "root"
  mode "644"
  notifies :run, "execute[restart memory-v2-proxy]"
end

# Standalone v2 ES index templates + setup script (the server self-bootstraps
# indices via ensure_indices on startup; kept for manual ops / migration).
es_indices_v2_dir = "#{base_dir}/es-indices-v2"
directory es_indices_v2_dir do
  owner "root"
  group "root"
  mode "755"
  action :create
end

%w[memory-fact.json memory-knowledge.json memory-episode.json memory-stats.json setup_indices_v2.sh].each do |f|
  remote_file "#{es_indices_v2_dir}/#{f}" do
    source "files/es-indices-v2/#{f}"
    owner "root"
    group "root"
    mode(f.end_with?(".sh") ? "755" : "644")
  end
end

# v2 .env (EnvironmentFile) from SSM. SECOND require_external_auth block, gated
# on the /memory/voyage-api-key param (the scoped fleet profile). The
# skip_if is CONTENT-AWARE (grep VOYAGE_API_KEY), not File.exist? — per
# ~/ManagedProjects/setup/.claude/rules/ruby.md the file-existence form makes a generator key change a
# silent no-op on a host whose .env predates it.
generate_env_v2_script = File.join(File.dirname(__FILE__), "files", "generate_env_v2.sh")
env_v2_temp_path = "#{generated_dir}/memory-v2.env"

require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /monitoring/elastic/* + /memory/voyage-api-key SSM params",
  check_command: "aws ssm get-parameter --name /memory/voyage-api-key " \
                 "--profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on " \
                "/monitoring/elastic/* and /memory/voyage-api-key in #{aws_region}. " \
                "On a fresh machine: aws configure --profile #{aws_profile}. " \
                "Then press Enter.",
  skip_if: -> { File.exist?(env_path_v2) && File.read(env_path_v2).include?("VOYAGE_API_KEY") },
) do
  execute "generate memory-v2 .env" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "bash #{generate_env_v2_script} #{env_v2_temp_path}"
    user node[:setup][:user]
  end
end

# Place the v2 env (converge-time only_if, not compile-time File.exist? — see
# ~/ManagedProjects/setup/.claude/rules/ruby.md mitamae evaluation model).
remote_file env_path_v2 do
  source env_v2_temp_path
  owner "root"
  group "root"
  mode "600"
  notifies :run, "execute[restart memory-mcp-v2]"
  notifies :run, "execute[restart memory-v2-proxy]"
  only_if "test -f #{env_v2_temp_path}"
end

file env_v2_temp_path do
  action :delete
  only_if "test -f #{env_v2_temp_path}"
end

# v2 systemd units (units_staging is declared above).
%w[memory-mcp-v2 memory-v2-proxy].each do |svc|
  staged = "#{units_staging}/#{svc}.service"
  remote_file staged do
    source "files/systemd/#{svc}.service"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
  end

  systemd_unit "#{svc}.service" do
    staging_path staged
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

remote_file keeper_health_script_staging do
  source "files/memory-keeper-health.sh"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
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
remote_file keeper_health_svc_staged do
  source "files/systemd/memory-keeper-health.service"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
end
systemd_unit "memory-keeper-health.service" do
  staging_path keeper_health_svc_staged
  start false
end

keeper_health_timer_staged = "#{units_staging}/memory-keeper-health.timer"
remote_file keeper_health_timer_staged do
  source "files/systemd/memory-keeper-health.timer"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
end
systemd_unit "memory-keeper-health.timer" do
  staging_path keeper_health_timer_staged
end

execute "ensure memory-keeper-health.timer active" do
  command "systemctl daemon-reload && systemctl enable --now memory-keeper-health.timer"
  not_if "systemctl is-active memory-keeper-health.timer >/dev/null 2>&1"
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
keeper_dir = "#{base_dir}/keeper"
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

# keeper python + prompts — every runtime file listed in
# files/memory-keeper/MANIFEST (ADR 0010; CI-checked, see the memory-mcp block
# above). A changed .py is picked up on the NEXT timer fire (each tick is a
# fresh /usr/bin/python3 process) — no unit restart needed.
memory_v2_manifest.call("memory-keeper").each do |rel|
  remote_file "#{keeper_dir}/#{rel}" do
    source "files/memory-keeper/#{rel}"
    owner "root"
    group "root"
    mode "644"
  end
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
  remote_file staged do
    source "files/systemd/#{unit}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
  end

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
