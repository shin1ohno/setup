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
end

remote_file "#{deploy_dir}/hydra.yml" do
  source "files/hydra.yml"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
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

execute "generate hydra .env" do
  command "bash #{generate_env_script} #{env_temp_path}"
  user node[:setup][:user]
end

if File.exist?(env_temp_path)
  remote_file env_output_path do
    source env_temp_path
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "600"
  end

  file env_temp_path do
    action :delete
  end
end

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

# Pull latest images and (re)start containers
execute "docker compose -f #{deploy_dir}/docker-compose.yml up -d --build --pull always" do
  user node[:setup][:user]
end
