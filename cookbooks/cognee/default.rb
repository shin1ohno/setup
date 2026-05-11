# frozen_string_literal: true

# Cognee — Knowledge graph memory engine backed by Kuzu + ChromaDB
# Deploys Docker Compose with cognee API, ChromaDB vector store, a
# drop-folder watcher, and an optional MCP server (profile-gated). LLM
# and embedding requests go directly to the OpenAI API (host CPUs
# without AVX2 cannot run fastembed/lancedb, so a remote provider is
# required).

return if node[:platform] == "darwin"

include_cookbook "awscli"

# Reuse the AWS profile / region convention from cookbooks/ssh-keys so the
# require_external_auth check_command and the .env generator both target the
# same IAM principal. Per CLAUDE.md "Auth-check gate must match the cookbook's
# actual invocation profile" — `aws sts get-caller-identity` is a false gate
# that passes against any default profile and lets the cookbook proceed even
# when the principal it actually invokes lacks /cognee/* SSM access.
ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

deploy_dir = "#{node[:setup][:home]}/deploy/cognee"

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

remote_file "#{deploy_dir}/docker-compose.yml" do
  source "files/docker-compose.yml"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  notifies :run, "execute[restart cognee]"
end

remote_file "#{deploy_dir}/entrypoint-override.sh" do
  source "files/entrypoint-override.sh"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  notifies :run, "execute[restart cognee]"
end

remote_file "#{deploy_dir}/cognee-gateway.conf" do
  source "files/cognee-gateway.conf"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  notifies :run, "execute[restart cognee]"
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
    notifies :run, "execute[restart cognee]"
  end
end

%w[Dockerfile proxy.py requirements.txt].each do |f|
  remote_file "#{deploy_dir}/auth-proxy/#{f}" do
    source "files/auth-proxy/#{f}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    notifies :run, "execute[restart cognee]"
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
    notifies :run, "execute[restart cognee]"
  end
end

remote_file "#{deploy_dir}/scripts/bulk_ingest.py" do
  source "files/scripts/bulk_ingest.py"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
end

# CPU-only override of cognee-mcp image. Removes ~5GB of dead nvidia/triton
# libs (CT 105 has no GPU passthrough) via uninstall + flatten
# (docker export | docker import). Plain layered uninstall would not shrink
# the image because parent layers persist in the image graph.
# See files/cognee-mcp-cpu/build.sh for idempotency stamp logic.
directory "#{deploy_dir}/cognee-mcp-cpu" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w[Dockerfile build.sh].each do |f|
  remote_file "#{deploy_dir}/cognee-mcp-cpu/#{f}" do
    source "files/cognee-mcp-cpu/#{f}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode(f == "build.sh" ? "755" : "644")
    notifies :run, "execute[build cognee-mcp:cpu]"
  end
end

execute "build cognee-mcp:cpu" do
  command "#{deploy_dir}/cognee-mcp-cpu/build.sh"
  user node[:setup][:user]
  action :nothing
  notifies :run, "execute[restart cognee]"
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
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /cognee/* SSM params",
  check_command: "aws ssm get-parameter --name /cognee/llm-endpoint " \
                 "--profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on /cognee/* in " \
                "#{aws_region}. On a fresh machine: aws configure --profile " \
                "#{aws_profile}. Then press Enter.",
  skip_if: -> { File.exist?(env_output_path) },
) do
  execute "generate cognee .env" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "bash #{generate_env_script} #{env_temp_path}"
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
  notifies :run, "execute[restart cognee]"
  only_if "test -f #{env_temp_path}"
end

file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path}"
end

# APM CA cert for the auth-proxy container's OTLP TLS handshake. Fetched
# separately from .env because the cookbook regenerates .env only on first
# apply (skip_if File.exist?(env_output_path)). The CA cert is similarly
# fetched once; manual rotation = delete this file and re-apply.
apm_ca_path = "#{deploy_dir}/apm-ca.crt"
execute "fetch apm-server CA cert for cognee auth-proxy" do
  command "aws ssm get-parameter --name /monitoring/apm/ca/cert " \
          "--profile #{aws_profile} --region #{aws_region} " \
          "--query Parameter.Value --output text > #{apm_ca_path} && " \
          "chmod 0644 #{apm_ca_path}"
  user node[:setup][:user]
  not_if "test -f #{apm_ca_path}"
  notifies :run, "execute[restart cognee]"
end

# Compose orchestration via the compose_service DSL
# (cookbooks/functions/default.rb). Emits `execute "ensure cognee running"`
# (idempotency probe + up -d --build) and `execute "restart cognee"`
# (action :nothing, --force-recreate, only_if env_path exists). All
# retro-learned guards (--force-recreate, only_if env-gate) are baked
# into the DSL so consumers inherit them by default.
compose_service "cognee" do
  compose_path "#{deploy_dir}/docker-compose.yml"
  deploy_dir deploy_dir
  env_path env_output_path
end
