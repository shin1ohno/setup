# frozen_string_literal: true
#
# lxc-consent (CT 110): Hydra consent app — Google OAuth login + DCR proxy
# + consent UI rendering.
#
# Tightly coupled to hydra LXC (admin API on
# node[:hydra_server][:lan_host]:4445, default hydra.home.local:4445) but
# isolated for per-service ZFS rollback granularity.
#
# Phase 0.5-Z Z-1 result determines path:
#   - consent native runtime confirmed (Python uvicorn) → could go native
#     systemd, but for now we keep docker compose to match the bare-metal
#     hydra cookbook layout exactly. Reduces config drift between the
#     two deployment topologies.
#
# RAM 0.5 GiB / CPU 1.

return if node[:platform] == "darwin"

include_cookbook "docker-engine"
include_cookbook "awscli"

user = node[:setup][:user]
group = node[:setup][:group]
deploy_dir = "#{node[:setup][:home]}/deploy/consent"

# Hydra admin reachable cross-LXC over the home.local DNS zone. Override
# per-deployment via node[:hydra_server][:lan_host] (e.g. when running
# against the bare-metal hydra deployment that lives on a different host).
hydra_lan_host = node.dig(:hydra_server, :lan_host) || "hydra.home.local"
hydra_admin_url = "http://#{hydra_lan_host}:4445"

directory deploy_dir do
  owner user
  group group
  mode "755"
end

%w[consent-app].each do |sub|
  directory "#{deploy_dir}/#{sub}" do
    owner user
    group group
    mode "755"
  end
end

# Consent app source — read from cookbooks/hydra/files/consent-app/ to
# keep one canonical implementation. Avoids byte-for-byte duplication
# between cookbooks/hydra and cookbooks/lxc-consent.
hydra_consent_dir = File.expand_path("../hydra/files/consent-app", File.dirname(__FILE__))
%w[Dockerfile requirements.txt app.py].each do |f|
  src_content = File.read("#{hydra_consent_dir}/#{f}")
  file "#{deploy_dir}/consent-app/#{f}" do
    owner user
    group group
    mode "644"
    content src_content
    notifies :run, "execute[restart consent]"
  end
end

# docker-compose.yml — single service (consent-app); hydra admin API
# reached over LAN at hydra_admin_url.
file "#{deploy_dir}/docker-compose.yml" do
  owner user
  group group
  mode "644"
  content <<~COMPOSE
    services:
      consent:
        build: ./consent-app
        container_name: hydra-consent
        restart: unless-stopped
        env_file: .env
        ports:
          - "9020:9020"
        environment:
          HYDRA_ADMIN_URL: #{hydra_admin_url}
          HYDRA_PUBLIC_URL: https://mcp.ohno.be
          GOOGLE_REDIRECT_URI: https://mcp.ohno.be/consent/google/callback
          PORT: 9020
  COMPOSE
  notifies :run, "execute[restart consent]"
end

# Generate .env from SSM (Google OAuth client_id/secret + ALLOWED_EMAILS).
# Reuses cookbooks/hydra (docker variant) SSM names — see
# cookbooks/hydra/files/generate_env.sh for the canonical paths.
generated_dir = "#{node[:setup][:root]}/generated"
directory generated_dir do
  owner user
  group group
  mode "755"
end

env_temp_path   = "#{generated_dir}/consent.env"
env_output_path = "#{deploy_dir}/.env"

require_external_auth(
  tool_name: "AWS CLI (for /hydra/* SSM params)",
  check_command: "aws ssm get-parameter --name /hydra/google-client-id --with-decryption --query Parameter.Value --output text >/dev/null 2>&1",
  instructions: "On a fresh machine: aws configure (or aws configure --profile <name> + export AWS_PROFILE=<name>). Then press Enter to retry.",
  skip_if: -> { File.exist?(env_output_path) },
) do
  execute "generate consent .env" do
    command <<~SH
      set -e
      umask 077
      GOOGLE_CLIENT_ID=$(aws ssm get-parameter --name /hydra/google-client-id --with-decryption --query Parameter.Value --output text)
      GOOGLE_CLIENT_SECRET=$(aws ssm get-parameter --name /hydra/google-client-secret --with-decryption --query Parameter.Value --output text)
      ALLOWED_EMAILS=$(aws ssm get-parameter --name /hydra/allowed-emails --with-decryption --query Parameter.Value --output text)
      cat > #{env_temp_path} <<EOF
      GOOGLE_CLIENT_ID=$GOOGLE_CLIENT_ID
      GOOGLE_CLIENT_SECRET=$GOOGLE_CLIENT_SECRET
      ALLOWED_EMAILS=$ALLOWED_EMAILS
      EOF
    SH
    user user
  end
end

remote_file env_output_path do
  source env_temp_path
  owner user
  group group
  mode "600"
  notifies :run, "execute[restart consent]"
  only_if "test -f #{env_temp_path}"
end

file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path}"
end

compose_path = "#{deploy_dir}/docker-compose.yml"
project_name = File.basename(deploy_dir)

execute "ensure consent running" do
  command "docker compose -f #{compose_path} up -d --build"
  user user
  only_if <<~SH.tr("\n", " ").strip
    test -f #{env_output_path} || exit 1;
    expected=$(docker compose -f #{compose_path} config --services 2>/dev/null | sort | tr '\\n' ' ');
    [ -n "$expected" ] || exit 1;
    running=$(docker ps --filter "label=com.docker.compose.project=#{project_name}"
                        --filter status=running --format '{{.Label "com.docker.compose.service"}}'
              | sort | tr '\\n' ' ');
    test "$running" = "$expected" && exit 1 || exit 0
  SH
end

execute "restart consent" do
  command "docker compose -f #{compose_path} up -d --build"
  user user
  action :nothing
end
