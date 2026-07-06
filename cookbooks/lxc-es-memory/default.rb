# frozen_string_literal: true

# es-memory-mcp — Mem0-compatible MCP server backed by the ElasticSearch
# cluster (es-0/1/2). Replaces the prior knowledge-graph (RDS pgvector / kuzu)
# and Mem0 (Qdrant / Aurora pgvector) storage stacks with BM25 + dense_vector
# kNN hybrid search on the existing 3-node ES cluster (basic license, no ML —
# embeddings computed externally via OpenAI text-embedding-3-small).
#
# Runs as native systemd units + a Python venv (NOT docker). Per the PVE LXC
# design gate (~/.claude/docs/pve-lxc-detail.md): a single-purpose service LXC
# prefers apt+venv+systemd over docker-compose, avoiding the docker-in-LXC bug
# class (bind-mount UID mapping, .env shell-interpretation, BuildKit failures,
# image pulls). Two units share one venv:
#
#   es-memory-mcp.service          uvicorn server:app  (127.0.0.1:8000)
#   es-memory-memory-proxy.service proxy.py PATH_PREFIX=/memory  (:8766)
#
# Tool names are preserved 1:1 so the existing claude.ai connector
# (mcp__claude_ai_ai_memory__*) keeps working.

return if node[:platform] == "darwin"

include_cookbook "awscli"

# Pin the scoped fleet AWS profile (pve-bootstrap-ssm) so the auth gate and the
# .env generator target the same IAM principal — see CLAUDE.md "Auth-check gate
# must match the cookbook's actual invocation profile".
ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

base_dir = "/opt/es-memory"
app_dir  = "#{base_dir}/app"
venv_dir = "#{base_dir}/venv"
env_path = "#{base_dir}/es-memory.env"

# Debian 13 minimal LXC ships without python3-venv/pip — see
# ~/.claude/docs/ruby-detail.md "Debian 13 Minimal LXC — Mandatory Bootstrap".
execute "install es-memory python deps" do
  command "apt-get update -qq && apt-get install -y python3 python3-venv python3-pip ca-certificates"
  not_if "dpkg -s python3-venv python3-pip >/dev/null 2>&1"
end

[base_dir, app_dir].each do |d|
  directory d do
    owner "root"
    group "root"
    mode "755"
    action :create
  end
end

# Restart executes (declared early so the file resources below can notify
# them). only_if guards the first converge, where the unit file is installed
# later in this same recipe by systemd_unit — restart is skipped until the
# unit exists, and systemd_unit's own activate starts it. The v2 units
# (memory-mcp-v2 / memory-v2-proxy) are included so the v2 file resources below
# can notify them the same way.
%w[es-memory-mcp es-memory-memory-proxy memory-mcp-v2 memory-v2-proxy].each do |svc|
  execute "restart #{svc}" do
    command "sudo systemctl restart #{svc}.service"
    action :nothing
    only_if "systemctl cat #{svc}.service >/dev/null 2>&1"
  end
end

# requirements + venv -------------------------------------------------------
remote_file "#{app_dir}/requirements.txt" do
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
          "#{venv_dir}/bin/pip install -r #{app_dir}/requirements.txt && " \
          "md5sum #{app_dir}/requirements.txt > #{venv_dir}/.reqs.md5"
  not_if "test -x #{venv_dir}/bin/uvicorn && test -f #{venv_dir}/.reqs.md5 && " \
         "md5sum -c --status #{venv_dir}/.reqs.md5"
  notifies :run, "execute[restart es-memory-mcp]"
  notifies :run, "execute[restart es-memory-memory-proxy]"
end

# Application code ----------------------------------------------------------
{
  "es-memory-mcp/server.py"     => "server.py",
  "es-memory-mcp/es_backend.py" => "es_backend.py",
}.each do |src, dest|
  remote_file "#{app_dir}/#{dest}" do
    source "files/#{src}"
    owner "root"
    group "root"
    mode "644"
    notifies :run, "execute[restart es-memory-mcp]"
  end
end

remote_file "#{app_dir}/proxy.py" do
  source "files/auth-proxy/proxy.py"
  owner "root"
  group "root"
  mode "644"
  notifies :run, "execute[restart es-memory-memory-proxy]"
end

# Standalone ES index templates + setup script (the server self-bootstraps
# indices on startup; kept for manual ops / migration).
es_indices_dir = "#{base_dir}/es-indices"
directory es_indices_dir do
  owner "root"
  group "root"
  mode "755"
  action :create
end

%w[knowledge.json memory-user.json setup_indices.sh].each do |f|
  remote_file "#{es_indices_dir}/#{f}" do
    source "files/es-indices/#{f}"
    owner "root"
    group "root"
    mode(f.end_with?(".sh") ? "755" : "644")
  end
end

# .env (EnvironmentFile) from SSM ------------------------------------------
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

generate_env_script = File.join(File.dirname(__FILE__), "files", "generate_env.sh")
env_temp_path = "#{generated_dir}/es-memory.env"

require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /monitoring/elastic/* + /memory/openai-api-key SSM params",
  check_command: "aws ssm get-parameter --name /monitoring/elastic/elastic-password " \
                 "--profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on " \
                "/monitoring/elastic/* and /memory/openai-api-key in #{aws_region}. " \
                "On a fresh machine: aws configure --profile #{aws_profile}. " \
                "Then press Enter.",
  skip_if: -> { File.exist?(env_path) },
) do
  execute "generate es-memory .env" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "bash #{generate_env_script} #{env_temp_path}"
    user node[:setup][:user]
  end
end

# Place the env (converge-time only_if, not compile-time File.exist? — see
# ~/.claude/rules/ruby.md mitamae evaluation model).
remote_file env_path do
  source env_temp_path
  owner "root"
  group "root"
  mode "600"
  notifies :run, "execute[restart es-memory-mcp]"
  only_if "test -f #{env_temp_path}"
end

file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path}"
end

# systemd units -------------------------------------------------------------
units_staging = "#{node[:setup][:root]}/es-memory"
directory units_staging do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w[es-memory-mcp es-memory-memory-proxy].each do |svc|
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

# ==========================================================================
# v2 (Voyage-embedding unified memory) — ADDITIVE alongside the v1 units above.
#
# The v2 units (memory-mcp-v2 + memory-v2-proxy) run from /opt/es-memory/app-v2
# and share the SAME venv (/opt/es-memory/venv) with requirements-v2.txt
# installed into it. The v1 units (es-memory-mcp / *-proxy) are left completely
# untouched for the cutover window — nothing below edits a v1 resource.
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
# v1 sentinel — the existing "pip install es-memory deps" execute above stays
# intact. md5-only guard (no binary probe): the v2 wheels land in the shared
# venv already populated by the v1 install.
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

# v2 application code: the 5 modules from files/memory-mcp/ + the shared auth
# proxy. proxy.py is the SAME source as v1 (files/auth-proxy/proxy.py); the v2
# enforcement matrix is env-gated (MEMORY_AUDIENCES) so one file serves both
# namespaces.
%w[server.py es_backend.py voyage.py scoring.py identity.py].each do |mod|
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
# on the new /memory/voyage-api-key param (same scoped profile as v1). The
# skip_if is CONTENT-AWARE (grep VOYAGE_API_KEY), not File.exist? — per
# ~/.claude/rules/ruby.md the file-existence form makes a generator key change a
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
# ~/.claude/rules/ruby.md mitamae evaluation model).
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

# v2 systemd units (staging dir units_staging declared above for the v1 units).
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

# keeper python + prompts. A changed .py is picked up on the NEXT timer fire
# (each tick is a fresh /usr/bin/python3 process) — no unit restart needed.
{
  "reconcile.py"         => "reconcile.py",
  "consolidate.py"       => "consolidate.py",
  "claude_judge.py"      => "claude_judge.py",
  "es_client.py"         => "es_client.py",
  "voyage_client.py"     => "voyage_client.py",
  "prompts/reconcile.md" => "prompts/reconcile.md",
  "prompts/promote.md"   => "prompts/promote.md",
}.each do |src, dest|
  remote_file "#{keeper_dir}/#{dest}" do
    source "files/memory-keeper/#{src}"
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
