# frozen_string_literal: true

# Cognee — Knowledge graph memory engine backed by Kuzu + ChromaDB
# Deploys Docker Compose with cognee API, ChromaDB vector store, a
# drop-folder watcher, and an optional MCP server (profile-gated). LLM
# and embedding requests go directly to the OpenAI API (host CPUs
# without AVX2 cannot run fastembed/lancedb, so a remote provider is
# required).

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

# Cognee MCP server runtime patches. Mounted as read-only volumes by the
# cognee-mcp container (see docker-compose.yml). Source of truth lives in
# this cookbook so mitamae re-runs cannot drift from the committed copy.
directory "#{deploy_dir}/patches" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w[mcp-server.py mcp-cognee-client.py].each do |f|
  remote_file "#{deploy_dir}/patches/#{f}" do
    source "files/patches/#{f}"
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

# Deploy and clean up at converge time. Replaces a compile-time
# `if File.exist?(env_temp_path)` that ran before the preceding execute,
# so on clean runs the resources were never declared.
remote_file env_output_path do
  source env_temp_path
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "600"
  notifies :run, "execute[docker compose restart cognee]"
  only_if "test -f #{env_temp_path}"
end

file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path}"
end

# Bring containers up. Requires .env in place; the only_if shell guard runs
# at converge time so this resource fires on the same run that generated
# .env (a previous compile-time `if File.exist?(env_output_path)` wrapper
# skipped declaration on clean runs).
compose_path = "#{deploy_dir}/docker-compose.yml"
project_name = File.basename(deploy_dir)
execute "ensure cognee running" do
  command "docker compose -f #{compose_path} up -d --build"
  user node[:setup][:user]
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

# Recreate containers when compose config or built image sources change.
# Notified by remote_file resources above; no-op otherwise.
# Defined unconditionally so notifies: resolve even before .env is generated.
execute "docker compose restart cognee" do
  command "docker compose -f #{deploy_dir}/docker-compose.yml up -d --build"
  user node[:setup][:user]
  action :nothing
end
