# frozen_string_literal: true
#
# hydra-server: Native systemd install of Ory Hydra (OAuth 2.0 / OIDC).
#
# Distinct from `cookbooks/hydra` which deploys via Docker Compose; this
# variant runs the Hydra Go binary directly under systemd. Used inside
# the dedicated hydra LXC (CT 106) per migration plan to drop docker
# daemon overhead (~200 MiB) for a single-binary service.
#
# Aurora DSN (DATABASE_URL) is fetched from SSM at apply-time and written
# to /etc/hydra/.env (root-owned, mode 600).
#
# SSM parameters are reused from cookbooks/hydra (docker variant) to
# avoid cross-repo coordination with home-monitor. See
# cookbooks/hydra/files/generate_env.sh for the canonical names.
#
# References:
#   - Phase 0.5-Z (Z-3): Aurora hydra db + role must already exist
#     (provisioned by home-monitor/rds.tf).
#   - frolicking-beaming-crescent.md Phase 6a: lxc-hydra includes this cookbook.

return if node[:platform] == "darwin"

include_cookbook "awscli"

HYDRA_VERSION = "v2.3.0"
HYDRA_BINARY  = "/usr/local/bin/hydra"
HYDRA_USER    = "hydra"
HYDRA_HOME    = "/etc/hydra"

# Admin port bind host. Default 127.0.0.1 keeps the unauthenticated admin
# API off the LAN. For lxc-consent (CT 110) cross-LXC access, override
# via node[:hydra_server][:admin_bind_host] = vmbr1 IP of lxc-hydra
# (typically 192.168.1.33). Out of scope: nftables rule restricting
# source to lxc-consent IP — recommended hardening if admin is exposed
# beyond loopback.
admin_bind_host = node.dig(:hydra_server, :admin_bind_host) || "127.0.0.1"

# 1. System user
execute "create hydra system user" do
  command "sudo useradd --system --no-create-home --shell /usr/sbin/nologin #{HYDRA_USER}"
  not_if "id -u #{HYDRA_USER} >/dev/null 2>&1"
end

# 2. Download Hydra Go binary from GitHub release.
# Ory's asset naming convention is linux_64bit (NOT linux_amd64).
# Verify with: gh api repos/ory/hydra/releases/tags/v2.3.0 --jq '.assets[].name'
hydra_archive = "#{node[:setup][:root]}/hydra-server/hydra_#{HYDRA_VERSION.delete_prefix("v")}-linux_64bit.tar.gz"
hydra_url     = "https://github.com/ory/hydra/releases/download/#{HYDRA_VERSION}/hydra_#{HYDRA_VERSION.delete_prefix("v")}-linux_64bit.tar.gz"

directory "#{node[:setup][:root]}/hydra-server" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

execute "download Ory Hydra #{HYDRA_VERSION}" do
  command "curl -fsSL -o #{hydra_archive} #{hydra_url}"
  user node[:setup][:user]
  not_if "test -f #{HYDRA_BINARY} && #{HYDRA_BINARY} version 2>&1 | grep -q '#{HYDRA_VERSION.delete_prefix("v")}'"
end

execute "extract + install hydra binary" do
  command <<~SH
    set -e
    cd #{node[:setup][:root]}/hydra-server
    tar -xzf #{File.basename(hydra_archive)}
    sudo install -m 755 -o root -g root hydra #{HYDRA_BINARY}
    rm hydra
  SH
  user node[:setup][:user]
  not_if "test -f #{HYDRA_BINARY} && #{HYDRA_BINARY} version 2>&1 | grep -q '#{HYDRA_VERSION.delete_prefix("v")}'"
end

# 3. Config directory
execute "create #{HYDRA_HOME}" do
  command "sudo install -d -m 755 -o root -g #{HYDRA_USER} #{HYDRA_HOME}"
  not_if "test -d #{HYDRA_HOME}"
end

# 4. Hydra config file — rendered from cookbooks/hydra-server/files/hydra.yml
# with admin bind host substitution. Full MCP-required sections (JWT,
# DCR, CORS, PKCE) live in the file resource itself.
hydra_config_staging = "#{node[:setup][:root]}/hydra-server/hydra.yml"
hydra_config_system  = "#{HYDRA_HOME}/hydra.yml"
hydra_config_template = File.read(File.expand_path("files/hydra.yml", __dir__))

file hydra_config_staging do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0644"
  content hydra_config_template.gsub("__ADMIN_BIND_HOST__", admin_bind_host)
end

execute "install hydra.yml" do
  command "sudo install -m 644 -o root -g #{HYDRA_USER} #{hydra_config_staging} #{hydra_config_system}"
  not_if "diff -q #{hydra_config_staging} #{hydra_config_system} 2>/dev/null"
  notifies :run, "execute[restart hydra]"
end

# 5. Generate .env from SSM (reuse cookbooks/hydra param names).
generated_dir = "#{node[:setup][:root]}/generated"
directory generated_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

env_temp_path   = "#{generated_dir}/hydra-server.env"
env_system_path = "#{HYDRA_HOME}/.env"

require_external_auth(
  tool_name: "AWS CLI (for /memory/aurora-* + /hydra/* SSM params)",
  check_command: "aws ssm get-parameter --name /memory/aurora-endpoint --query Parameter.Value --output text >/dev/null 2>&1",
  instructions: "On a fresh machine: aws configure (or aws configure --profile <name> + export AWS_PROFILE=<name>). Then press Enter to retry.",
  skip_if: -> { File.exist?(env_system_path) },
) do
  execute "generate hydra-server .env" do
    command <<~SH
      set -e
      umask 077
      AURORA_ENDPOINT=$(aws ssm get-parameter --name /memory/aurora-endpoint --query Parameter.Value --output text)
      HYDRA_PASSWORD=$(aws ssm get-parameter --name /hydra/aurora-password --with-decryption --query Parameter.Value --output text)
      SECRETS_SYSTEM=$(aws ssm get-parameter --name /hydra/system-secret --with-decryption --query Parameter.Value --output text)
      cat > #{env_temp_path} <<EOF
      DSN=postgres://hydra:$HYDRA_PASSWORD@$AURORA_ENDPOINT:5432/hydra?sslmode=require
      SECRETS_SYSTEM=$SECRETS_SYSTEM
      EOF
    SH
    user node[:setup][:user]
  end
end

execute "install hydra-server .env" do
  command "sudo install -m 600 -o root -g #{HYDRA_USER} #{env_temp_path} #{env_system_path}"
  only_if "test -f #{env_temp_path}"
  notifies :run, "execute[restart hydra]"
end

file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path}"
end

# 6. Run hydra migrate sql once (marker file gate).
# Run as root to avoid HOME / permission issues with --no-create-home
# system user. The migration is one-shot, so user isolation provides
# little value here.
db_marker = "#{HYDRA_HOME}/.hydra-migrated"
execute "hydra migrate sql" do
  command "sudo bash -c 'set -a; . #{env_system_path}; set +a; #{HYDRA_BINARY} migrate sql --yes' && sudo touch #{db_marker}"
  only_if "test -f #{env_system_path} && ! test -f #{db_marker}"
end

# 7. systemd unit
unit_staging = "#{node[:setup][:root]}/hydra-server/hydra.service"
unit_system  = "/etc/systemd/system/hydra.service"

file unit_staging do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0644"
  content <<~UNIT
    [Unit]
    Description=Ory Hydra OAuth 2.0 / OIDC server
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=simple
    User=#{HYDRA_USER}
    Group=#{HYDRA_USER}
    EnvironmentFile=#{env_system_path}
    ExecStart=#{HYDRA_BINARY} serve all --config #{hydra_config_system}
    Restart=on-failure
    RestartSec=5
    LimitNOFILE=65536

    [Install]
    WantedBy=multi-user.target
  UNIT
end

execute "install hydra systemd unit" do
  command "sudo install -m 644 -o root -g root #{unit_staging} #{unit_system}"
  not_if "diff -q #{unit_staging} #{unit_system} 2>/dev/null"
  notifies :run, "execute[hydra systemctl daemon-reload]"
end

execute "hydra systemctl daemon-reload" do
  command "sudo systemctl daemon-reload && sudo systemctl restart hydra"
  action :nothing
end

execute "enable + start hydra" do
  command "sudo systemctl enable --now hydra.service"
  not_if "systemctl is-enabled hydra.service 2>/dev/null | grep -q '^enabled$' && systemctl is-active --quiet hydra.service"
  only_if "test -f #{env_system_path} && test -f #{db_marker}"
end

execute "restart hydra" do
  command "sudo systemctl restart hydra.service"
  action :nothing
end
