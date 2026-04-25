# frozen_string_literal: true

# Cognee — Knowledge graph memory engine backed by Kuzu + ChromaDB
# Deploys Docker Compose with cognee API, ChromaDB vector store, a
# drop-folder watcher, and an optional MCP server (profile-gated). LLM
# and embedding requests are routed through the existing litellm proxy
# (host CPUs without AVX2 cannot run fastembed/lancedb).

return if node[:platform] == "darwin"

include_cookbook "awscli"

deploy_dir = "#{node[:setup][:home]}/deploy/cognee"
vault_dir = "#{node[:setup][:home]}/ObsidianVaults/cognee-generated"

directory deploy_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w[data system ingest ingest/drop watcher scripts auth-proxy].each do |sub|
  directory "#{deploy_dir}/#{sub}" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    action :create
  end
end

# chroma_data is written by the ChromaDB container (runs as root);
# only ensure the directory exists — do not enforce ownership.
directory "#{deploy_dir}/chroma_data" do
  mode "755"
  action :create
end

directory vault_dir do
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
  notifies :run, "execute[docker compose restart cognee]"
end

remote_file "#{deploy_dir}/entrypoint-override.sh" do
  source "files/entrypoint-override.sh"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  notifies :run, "execute[docker compose restart cognee]"
end

remote_file "#{deploy_dir}/cognee-gateway.conf" do
  source "files/cognee-gateway.conf"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  notifies :run, "execute[docker compose restart cognee]"
end

remote_file "#{deploy_dir}/.env.example" do
  source "files/.env.example"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
end

%w[Dockerfile watch.py].each do |f|
  remote_file "#{deploy_dir}/watcher/#{f}" do
    source "files/watcher/#{f}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    notifies :run, "execute[docker compose restart cognee]"
  end
end

%w[Dockerfile proxy.py requirements.txt].each do |f|
  remote_file "#{deploy_dir}/auth-proxy/#{f}" do
    source "files/auth-proxy/#{f}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    notifies :run, "execute[docker compose restart cognee]"
  end
end

%w[bulk_ingest.py export_vault.py watch_and_export.py].each do |f|
  remote_file "#{deploy_dir}/scripts/#{f}" do
    source "files/scripts/#{f}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
  end
end

directory "#{deploy_dir}/vault-exporter" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

remote_file "#{deploy_dir}/vault-exporter/Dockerfile" do
  source "files/vault-exporter/Dockerfile"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  notifies :run, "execute[docker compose restart cognee]"
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
env_temp_path = "#{generated_dir}/cognee.env"
env_output_path = "#{deploy_dir}/.env"

# Skip generation if .env already exists — edit by hand to override
require_external_auth(
  tool_name: "AWS CLI (for /cognee/* SSM params)",
  check_command: "aws sts get-caller-identity",
  instructions: "On a fresh machine: aws configure (or aws configure --profile <name> + export AWS_PROFILE=<name>). Then press Enter to retry.",
  skip_if: -> { File.exist?(env_output_path) },
) do
  execute "generate cognee .env" do
    command "bash #{generate_env_script} #{env_temp_path}"
    user node[:setup][:user]
  end
end

if File.exist?(env_temp_path)
  remote_file env_output_path do
    source env_temp_path
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "600"
    notifies :run, "execute[docker compose restart cognee]"
  end

  file env_temp_path do
    action :delete
  end
end

# Everything below requires .env — skip if not yet generated
if File.exist?(env_output_path)
  compose_path = "#{deploy_dir}/docker-compose.yml"

  # Ensure containers are running (cheap idempotency check). Fires only when a
  # declared service is not currently running.
  execute "ensure cognee running" do
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
end

# Recreate containers when compose config or built image sources change.
# Notified by remote_file resources above; no-op otherwise.
# Defined unconditionally so notifies: resolve even before .env is generated.
execute "docker compose restart cognee" do
  command "docker compose -f #{deploy_dir}/docker-compose.yml up -d --build"
  user node[:setup][:user]
  action :nothing
end
