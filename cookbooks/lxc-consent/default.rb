# frozen_string_literal: true
#
# cookbooks/lxc-consent: the consent LXC (CT 110) service logic, extracted from
# pve/lxc-consent.rb (Phase 4 structural refactor). The thin entry recipe
# includes this cookbook then calls lxc_entry. consent is the Hydra consent app
# (Google OAuth login + DCR proxy + consent UI), reached via mcp.ohno.be.
#
# NOTE: the /hydra/* SSM auth gate below is intentionally left BARE-profile
# (verbatim from the entry recipe). The case-B profile unification (D5 —
# bare -> explicit --profile) is a separate follow-up gated on the /hydra/*
# profile probe; this PR is a behavior-preserving extraction only.

user = ENV["USER"]
group = `id -gn`.strip

include_cookbook "docker-engine"
include_cookbook "awscli"

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

# Consent app source — read from cookbooks/consent-app/files/ (a files-only
# cookbook, no resources of its own). This cookbook reads the 3 files via
# File.read and embeds them as `file ... content` resources. The path is a
# sibling-cookbook relative ref (File.dirname(__FILE__) is cookbooks/lxc-consent,
# so "../consent-app/files" resolves to cookbooks/consent-app/files). If the
# consent app outgrows this pattern, promote cookbooks/consent-app/ to a real
# service primitive.
consent_app_dir = File.expand_path("../consent-app/files", File.dirname(__FILE__))
%w[Dockerfile requirements.txt app.py].each do |f|
  src_content = File.read("#{consent_app_dir}/#{f}")
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
        # Static /etc/hosts injection for hydra. Belt-and-suspenders alongside
        # the `dns:` block below: when the unbound resolver (192.168.1.61)
        # SERVFAILs the home.local zone (observed when its upstream VPC
        # resolver via Tailscale is unreachable), the container's DNS lookup
        # falls back to /etc/hosts and resolves anyway. Without this,
        # `httpx.ConnectError: [Errno -2] Name or service not known` on the
        # DCR proxy POST → claude.ai sees 500 on /oauth2/register → MCP
        # connect fails with "Couldn't reach the MCP server". The same
        # name + IP is in `local.devices.hydra` in home-monitor devices.tf;
        # hardcoded here per ~/.claude/rules/cookbook-prs.md (IP literals
        # in cookbooks must match contracts/devices.json — verified).
        extra_hosts:
          - "hydra.home.local:192.168.1.71"
        # Default Docker container DNS does not include the LAN's home.local
        # zone. Point at the unbound resolver (CT118, 192.168.1.61), which
        # forwards home.local to VPC Route53. consent's DCR proxy and admin
        # API client (HYDRA_ADMIN_URL → hydra.home.local:4445) would otherwise
        # fail to resolve and abort with `httpx.ConnectError: [Errno -2] Name
        # or service not known`, surfacing as HTTP 500 on /oauth2/register.
        dns:
          - 192.168.1.61
          - 1.1.1.1
        environment:
          HYDRA_ADMIN_URL: #{hydra_admin_url}
          HYDRA_PUBLIC_URL: https://mcp.ohno.be
          GOOGLE_REDIRECT_URI: https://mcp.ohno.be/consent/google/callback
          PORT: 9020
  COMPOSE
  notifies :run, "execute[restart consent]"
end

# Generate .env from SSM (Google OAuth client_id/secret + ALLOWED_EMAILS).
# Reuses the hydra (docker variant) SSM names.
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

# Compose orchestration via the compose_service DSL
# (cookbooks/functions/default.rb). buildkit: false forces
# DOCKER_BUILDKIT=0 because consent runs in an unprivileged LXC where
# BuildKit's mount namespacing trips up despite features_nesting=true
# (see ~/.claude/rules/pve-lxc.md "Docker Build in Unprivileged PVE
# LXC"). The compose spec has only one local-build service
# (consent-app/Dockerfile) with no #ref:subdir context, so the classic
# builder is sufficient.
compose_service "consent" do
  compose_path "#{deploy_dir}/docker-compose.yml"
  deploy_dir deploy_dir
  env_path env_output_path
  buildkit false
end
