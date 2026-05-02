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
# References:
#   - Phase 0.5-Z (Z-3): Aurora hydra db + role must already exist
#     (provisioned by home-monitor/rds.tf). Phase 0.5-D PR may need to add
#     these if missing.
#   - frolicking-beaming-crescent.md Phase 6a: lxc-hydra includes this cookbook

return if node[:platform] == "darwin"

include_cookbook "awscli"

HYDRA_VERSION = "v2.3.0"
HYDRA_BINARY  = "/usr/local/bin/hydra"
HYDRA_USER    = "hydra"
HYDRA_HOME    = "/etc/hydra"

# 1. System user
execute "create hydra system user" do
  command "sudo useradd --system --no-create-home --shell /usr/sbin/nologin #{HYDRA_USER}"
  not_if "id -u #{HYDRA_USER} >/dev/null 2>&1"
end

# 2. Download Hydra Go binary from GitHub release
hydra_archive = "#{node[:setup][:root]}/hydra-server/hydra_#{HYDRA_VERSION.delete_prefix("v")}_linux_amd64.tar.gz"
hydra_url     = "https://github.com/ory/hydra/releases/download/#{HYDRA_VERSION}/hydra_#{HYDRA_VERSION.delete_prefix("v")}-linux_amd64.tar.gz"

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

# 4. Hydra config file
hydra_config_staging = "#{node[:setup][:root]}/hydra-server/hydra.yml"
hydra_config_system  = "#{HYDRA_HOME}/hydra.yml"

file hydra_config_staging do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0644"
  content <<~YAML
    serve:
      public:
        port: 4444
        host: 0.0.0.0
      admin:
        port: 4445
        host: 0.0.0.0
    urls:
      self:
        issuer: https://mcp.ohno.be
        public: https://mcp.ohno.be
      consent: https://mcp.ohno.be/consent/
      login: https://mcp.ohno.be/consent/login
      logout: https://mcp.ohno.be/consent/logout
    secrets:
      system:
        - ${SECRETS_SYSTEM}
    oidc:
      subject_identifiers:
        supported_types:
          - public
    ttl:
      access_token: 1h
      id_token: 1h
      refresh_token: 720h
    log:
      level: info
      format: json
  YAML
end

execute "install hydra.yml" do
  command "sudo install -m 644 -o root -g #{HYDRA_USER} #{hydra_config_staging} #{hydra_config_system}"
  not_if "diff -q #{hydra_config_staging} #{hydra_config_system} 2>/dev/null"
  notifies :run, "execute[restart hydra]"
end

# 5. Generate .env from SSM
generated_dir = "#{node[:setup][:root]}/generated"
directory generated_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

env_temp_path   = "#{generated_dir}/hydra-server.env"
env_system_path = "#{HYDRA_HOME}/.env"

require_external_auth(
  tool_name: "AWS CLI (for /hydra/* SSM params)",
  check_command: "aws sts get-caller-identity",
  instructions: "On a fresh machine: aws configure (or aws configure --profile <name> + export AWS_PROFILE=<name>). Then press Enter to retry.",
  skip_if: -> { File.exist?(env_system_path) },
) do
  execute "generate hydra-server .env" do
    command <<~SH
      set -e
      AURORA_ENDPOINT=$(aws ssm get-parameter --name /hydra/aurora-endpoint --query Parameter.Value --output text)
      HYDRA_PASSWORD=$(aws ssm get-parameter --name /hydra/hydra-db-password --with-decryption --query Parameter.Value --output text)
      SECRETS_SYSTEM=$(aws ssm get-parameter --name /hydra/secrets-system --with-decryption --query Parameter.Value --output text)
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

# 6. Run hydra migrate sql once (marker file gate)
db_marker = "#{HYDRA_HOME}/.hydra-migrated"
execute "hydra migrate sql" do
  command "sudo -u #{HYDRA_USER} bash -c 'set -a; . #{env_system_path}; set +a; #{HYDRA_BINARY} migrate sql --yes' && sudo touch #{db_marker}"
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
