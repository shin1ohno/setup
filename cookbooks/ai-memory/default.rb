# frozen_string_literal: true

# OpenMemory MCP — AI memory layer backed by Aurora Serverless v2 (pgvector)
# Deploys Docker Compose with openmemory-api and openmemory-ui.
# Requires docker-engine cookbook to be included before this cookbook.

return if node[:platform] == "darwin"

include_cookbook "awscli"

deploy_dir = "#{node[:setup][:home]}/deploy/memory"

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

# Auth proxy — validates sage OAuth tokens in front of openmemory-api
auth_proxy_dir = "#{deploy_dir}/auth-proxy"
directory auth_proxy_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w[Dockerfile requirements.txt proxy.py].each do |f|
  remote_file "#{auth_proxy_dir}/#{f}" do
    source "files/auth-proxy/#{f}"
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
env_temp_path = "#{generated_dir}/ai-memory.env"
env_output_path = "#{deploy_dir}/.env"

execute "generate ai-memory .env" do
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

# Ensure pgvector extension exists on Aurora (uses ephemeral postgres container)
execute "enable pgvector extension on Aurora" do
  command %W[
    docker run --rm --env-file #{deploy_dir}/.env
    postgres:16-alpine
    sh -c 'psql "$DATABASE_URL" -c "CREATE EXTENSION IF NOT EXISTS vector;"'
  ].join(" ")
  user node[:setup][:user]
end

# Pull latest images and (re)start containers; wait for health checks to pass
execute "docker compose -f #{deploy_dir}/docker-compose.yml up -d --pull always --wait --wait-timeout 120" do
  user node[:setup][:user]
end
