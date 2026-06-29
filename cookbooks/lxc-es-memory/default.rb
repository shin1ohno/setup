# frozen_string_literal: true

# es-memory-mcp — unified Cognee + Mem0 MCP server backed by the ElasticSearch
# cluster (es-0/1/2). Replaces the Cognee (RDS pgvector / kuzu) and Mem0
# (Qdrant / Aurora pgvector) storage stacks with BM25 + dense_vector kNN
# hybrid search on the existing 3-node ES cluster (basic license, no ML —
# embeddings computed externally via OpenAI text-embedding-3-small).
#
# Runs as native systemd units + a Python venv (NOT docker). Per the PVE LXC
# design gate (~/.claude/rules/pve-lxc.md): a single-purpose service LXC
# prefers apt+venv+systemd over docker-compose, avoiding the docker-in-LXC bug
# class (bind-mount UID mapping, .env shell-interpretation, BuildKit failures,
# image pulls). Three units share one venv:
#
#   es-memory-mcp.service          uvicorn server:app  (127.0.0.1:8000)
#   es-memory-cognee-proxy.service proxy.py PATH_PREFIX=/cognee  (:8002)
#   es-memory-memory-proxy.service proxy.py PATH_PREFIX=/memory  (:8766)
#
# Tool names are preserved 1:1 so the existing claude.ai connectors
# (mcp__claude_ai_cognee__*, mcp__claude_ai_ai_memory__*) keep working.

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
# ~/.claude/rules/pve-lxc.md "Debian 13 Minimal LXC — Mandatory Bootstrap".
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
# unit exists, and systemd_unit's own activate starts it.
%w[es-memory-mcp es-memory-cognee-proxy es-memory-memory-proxy].each do |svc|
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
  notifies :run, "execute[pip install es-memory deps]"
end

execute "create es-memory venv" do
  command "python3 -m venv #{venv_dir}"
  not_if "test -x #{venv_dir}/bin/python"
  notifies :run, "execute[pip install es-memory deps]"
end

execute "pip install es-memory deps" do
  command "#{venv_dir}/bin/pip install --upgrade pip && " \
          "#{venv_dir}/bin/pip install -r #{app_dir}/requirements.txt"
  action :nothing
  notifies :run, "execute[restart es-memory-mcp]"
  notifies :run, "execute[restart es-memory-cognee-proxy]"
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
  notifies :run, "execute[restart es-memory-cognee-proxy]"
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
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /monitoring/elastic/* + /mcp/* SSM params",
  check_command: "aws ssm get-parameter --name /monitoring/elastic/elastic-password " \
                 "--profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on " \
                "/monitoring/elastic/* and /mcp/openai-api-key in #{aws_region}. " \
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

%w[es-memory-mcp es-memory-cognee-proxy es-memory-memory-proxy].each do |svc|
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
