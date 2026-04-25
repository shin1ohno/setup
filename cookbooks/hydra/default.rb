# frozen_string_literal: true

# Ory Hydra — OAuth 2.0 / OIDC authorization server backed by Aurora (PostgreSQL)
# Deploys Docker Compose with hydra, hydra-migrate, and consent app.
# Requires docker-engine cookbook to be included before this cookbook.

return if node[:platform] == "darwin"

include_cookbook "awscli"

deploy_dir = "#{node[:setup][:home]}/deploy/hydra"

directory deploy_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

remote_file "#{deploy_dir}/docker-compose.yml" do
  source "files/docker-compose.yml"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  notifies :run, "execute[docker compose restart hydra]"
end

remote_file "#{deploy_dir}/hydra.yml" do
  source "files/hydra.yml"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  notifies :run, "execute[docker compose restart hydra]"
end

remote_file "#{deploy_dir}/setup-hydra.sh" do
  source "files/setup-hydra.sh"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# Consent app — Google OAuth login + Hydra consent flow
consent_app_dir = "#{deploy_dir}/consent-app"
directory consent_app_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w[Dockerfile requirements.txt app.py].each do |f|
  remote_file "#{consent_app_dir}/#{f}" do
    source "files/consent-app/#{f}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    notifies :run, "execute[docker compose restart hydra]"
  end
end

# Generate .env with secrets from SSM Parameter Store
generated_dir = "#{node[:setup][:root]}/generated"
directory generated_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

generate_env_script = File.join(File.dirname(__FILE__), "files", "generate_env.sh")
env_temp_path = "#{generated_dir}/hydra.env"
env_output_path = "#{deploy_dir}/.env"

# Generate .env — skip if SSM parameters are not yet registered
# (run setup-hydra.sh first, then re-run mitamae)
unless File.exist?(env_output_path)
  await_external_auth(
    tool_name: "AWS CLI (for /hydra/* SSM params)",
    check_command: "aws sts get-caller-identity",
    instructions: "On a fresh machine: aws configure (or aws configure --profile <name> + export AWS_PROFILE=<name>). Then press Enter to retry.",
  )
end

execute "generate hydra .env" do
  command "bash #{generate_env_script} #{env_temp_path}"
  user node[:setup][:user]
  not_if "test -f #{env_output_path}"
end

if File.exist?(env_temp_path)
  remote_file env_output_path do
    source env_temp_path
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "600"
    notifies :run, "execute[docker compose restart hydra]"
  end

  file env_temp_path do
    action :delete
  end
end

# Everything below requires .env — skip if not yet generated
if File.exist?(env_output_path)
  # Create hydra database on Aurora (uses ephemeral postgres container)
  execute "create hydra database on Aurora" do
    command %W[
      docker run --rm --env-file #{deploy_dir}/.env
      postgres:16-alpine
      sh -c 'psql "postgresql://hydra:${HYDRA_PASSWORD}@${AURORA_ENDPOINT}:5432/postgres?sslmode=require"
      -c "SELECT 1 FROM pg_database WHERE datname = '"'"'hydra'"'"'" | grep -q 1 ||
      psql "postgresql://hydra:${HYDRA_PASSWORD}@${AURORA_ENDPOINT}:5432/postgres?sslmode=require"
      -c "CREATE DATABASE hydra;"'
    ].join(" ")
    user node[:setup][:user]
    not_if %W[
      docker run --rm --env-file #{deploy_dir}/.env
      postgres:16-alpine
      sh -c 'psql "postgresql://hydra:${HYDRA_PASSWORD}@${AURORA_ENDPOINT}:5432/postgres?sslmode=require"
      -tc "SELECT 1 FROM pg_database WHERE datname = '"'"'hydra'"'"'" | grep -q 1'
    ].join(" ")
  end

  compose_path = "#{deploy_dir}/docker-compose.yml"

  # Ensure containers are running (cheap idempotency check). Fires only when a
  # declared service is not currently running.
  execute "ensure hydra running" do
    command "docker compose -f #{compose_path} up -d --build"
    user node[:setup][:user]
    only_if <<~SH.tr("\n", " ").strip
      services=$(docker compose -f #{compose_path} config --services 2>/dev/null);
      [ -n "$services" ] || exit 1;
      for s in $services; do
        docker compose -f #{compose_path} ps --services --filter status=running 2>/dev/null | grep -qx "$s" || exit 0;
      done;
      exit 1
    SH
  end
else
  MItamae.logger.info "hydra: .env not found — run ~/deploy/hydra/setup-hydra.sh first, then re-run mitamae"
end

# Recreate containers when compose config or built image sources change.
# Notified by remote_file resources above; no-op otherwise.
# Defined unconditionally so notifies: resolve even before .env is generated.
execute "docker compose restart hydra" do
  command "docker compose -f #{deploy_dir}/docker-compose.yml up -d --build"
  user node[:setup][:user]
  action :nothing
end
