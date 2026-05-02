# frozen_string_literal: true
#
# memory-server: Native Python venv + systemd install of OpenMemory MCP.
#
# Distinct from `cookbooks/ai-memory` which deploys via Docker Compose;
# this variant installs openmemory-mcp from PyPI into a Python venv and
# runs it under systemd. Used inside dedicated memory LXC (CT 107) per
# migration plan to drop docker daemon overhead.
#
# IMPORTANT: this cookbook assumes the openmemory PyPI package is
# functionally complete (Phase 0.5-Z Z-2 must verify). If the upstream
# only ships docker images (Z-2 = docker-only), lxc-memory should fall
# back to a docker compose path and skip this cookbook. Comment block
# below documents the bypass.

return if node[:platform] == "darwin"

# Phase 0.5-Z Z-2 escape hatch — set MEMORY_SERVER_DOCKER_FALLBACK=1 if
# `pip install openmemory-mcp` does not provide a usable server.
if ENV["MEMORY_SERVER_DOCKER_FALLBACK"] == "1"
  MItamae.logger.warn("memory-server: MEMORY_SERVER_DOCKER_FALLBACK=1 set, skipping native install (use docker compose path)")
  return
end

include_cookbook "awscli"

MEMORY_USER  = "openmemory"
MEMORY_HOME  = "/opt/openmemory"
MEMORY_VENV  = "#{MEMORY_HOME}/venv"
MEMORY_PYTHON = "#{MEMORY_VENV}/bin/python3"
MEMORY_PIP    = "#{MEMORY_VENV}/bin/pip"

# 1. Required packages: python3-venv, build-essential (for native deps)
%w[python3 python3-venv python3-dev build-essential].each do |pkg|
  package pkg do
    user node[:setup][:system_user]
    not_if { run_command("dpkg-query -W -f='${Status}' #{pkg} 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end
end

# 2. System user
execute "create openmemory system user" do
  command "sudo useradd --system --create-home --home-dir #{MEMORY_HOME} --shell /usr/sbin/nologin #{MEMORY_USER}"
  not_if "id -u #{MEMORY_USER} >/dev/null 2>&1"
end

# 3. Python venv
execute "create openmemory venv" do
  command "sudo -u #{MEMORY_USER} python3 -m venv #{MEMORY_VENV}"
  not_if "test -x #{MEMORY_PYTHON}"
end

# 4. Install openmemory-mcp from PyPI
execute "pip install openmemory-mcp" do
  command "sudo -u #{MEMORY_USER} #{MEMORY_PIP} install --upgrade openmemory-mcp"
  not_if "sudo -u #{MEMORY_USER} #{MEMORY_PIP} show openmemory-mcp 2>/dev/null | grep -q '^Name:'"
end

# 5. Generate .env from SSM
generated_dir = "#{node[:setup][:root]}/generated"
directory generated_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

env_temp_path   = "#{generated_dir}/memory-server.env"
env_system_path = "#{MEMORY_HOME}/.env"

# Reuses cookbooks/ai-memory SSM names (/memory/* + /mcp/*) to avoid
# requiring new SSM writes on home-monitor for this PR. openmemory-mcp
# shares the mem0 user / mem0 database. Phase 0.5-Z Z-2 verifies
# schema co-existence; if upstream openmemory needs an isolated DB,
# follow-up PR adds /memory/openmemory-* params + dedicated DB role.
require_external_auth(
  tool_name: "AWS CLI (for /memory/* + /mcp/openai-api-key SSM params)",
  check_command: "aws ssm get-parameter --name /memory/aurora-endpoint --query Parameter.Value --output text >/dev/null 2>&1",
  instructions: "On a fresh machine: aws configure (or aws configure --profile <name> + export AWS_PROFILE=<name>). Then press Enter to retry.",
  skip_if: -> { File.exist?(env_system_path) },
) do
  execute "generate memory-server .env" do
    command <<~SH
      set -e
      AURORA_ENDPOINT=$(aws ssm get-parameter --name /memory/aurora-endpoint --query Parameter.Value --output text)
      AURORA_PASSWORD=$(aws ssm get-parameter --name /memory/aurora-password --with-decryption --query Parameter.Value --output text)
      OPENAI_KEY=$(aws ssm get-parameter --name /mcp/openai-api-key --with-decryption --query Parameter.Value --output text)
      cat > #{env_temp_path} <<EOF
      DATABASE_URL=postgresql://mem0:$AURORA_PASSWORD@$AURORA_ENDPOINT:5432/mem0?sslmode=require
      OPENAI_API_KEY=$OPENAI_KEY
      OPENMEMORY_HOST=0.0.0.0
      OPENMEMORY_PORT=8766
      EOF
    SH
    user node[:setup][:user]
  end
end

execute "install memory-server .env" do
  command "sudo install -m 600 -o #{MEMORY_USER} -g #{MEMORY_USER} #{env_temp_path} #{env_system_path}"
  only_if "test -f #{env_temp_path}"
  notifies :run, "execute[restart openmemory]"
end

file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path}"
end

# 6. systemd unit
unit_staging = "#{node[:setup][:root]}/memory-server/openmemory.service"
unit_system  = "/etc/systemd/system/openmemory.service"

directory "#{node[:setup][:root]}/memory-server" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

file unit_staging do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0644"
  content <<~UNIT
    [Unit]
    Description=OpenMemory MCP server
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=simple
    User=#{MEMORY_USER}
    Group=#{MEMORY_USER}
    WorkingDirectory=#{MEMORY_HOME}
    EnvironmentFile=#{env_system_path}
    ExecStart=#{MEMORY_VENV}/bin/openmemory serve --host 0.0.0.0 --port 8766
    Restart=on-failure
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
  UNIT
end

execute "install openmemory systemd unit" do
  command "sudo install -m 644 -o root -g root #{unit_staging} #{unit_system}"
  not_if "diff -q #{unit_staging} #{unit_system} 2>/dev/null"
  notifies :run, "execute[openmemory systemctl daemon-reload]"
end

execute "openmemory systemctl daemon-reload" do
  command "sudo systemctl daemon-reload && sudo systemctl restart openmemory"
  action :nothing
end

execute "enable + start openmemory" do
  command "sudo systemctl enable --now openmemory.service"
  not_if "systemctl is-enabled openmemory.service 2>/dev/null | grep -q '^enabled$' && systemctl is-active --quiet openmemory.service"
  only_if "test -f #{env_system_path}"
end

execute "restart openmemory" do
  command "sudo systemctl restart openmemory.service"
  action :nothing
end
