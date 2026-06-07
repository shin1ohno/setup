# frozen_string_literal: true

# OpenMemory MCP — AI memory layer backed by Aurora Serverless v2 (pgvector)
# Deploys Docker Compose with openmemory-api and openmemory-ui.
# Requires docker-engine cookbook to be included before this cookbook.

return if node[:platform] == "darwin"

include_cookbook "awscli"

# Reuse the AWS profile / region convention from cookbooks/ssh-keys so the
# require_external_auth check_command and the .env generator both target the
# same IAM principal. Per CLAUDE.md "Auth-check gate must match the cookbook's
# actual invocation profile" — `aws sts get-caller-identity` is a false gate
# that passes against any default profile and lets the cookbook proceed even
# when the principal it actually invokes lacks /memory/* SSM access.
ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

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
  notifies :run, "execute[restart memory]"
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
    notifies :run, "execute[restart memory]"
  end
end

# Patched openmemory app/database.py — bind-mounted into the container
# at /usr/src/openmemory/app/database.py to disable SQLite-only
# `check_same_thread` flag for PostgreSQL deployments. Without this the
# upstream openmemory image rejects pgvector with
# `TypeError: 'check_same_thread' is an invalid keyword argument for
# this function`. Mount target referenced from
# cookbooks/lxc-memory/files/docker-compose.yml.
patches_dir = "#{deploy_dir}/patches"
directory patches_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

remote_file "#{patches_dir}/database.py" do
  source "files/patches/database.py"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  notifies :run, "execute[restart memory]"
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

require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /memory/* SSM params",
  check_command: "aws ssm get-parameter --name /memory/aurora-endpoint " \
                 "--profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on /memory/* and " \
                "/monitoring/apm/* in #{aws_region}. On a fresh machine: " \
                "aws configure --profile #{aws_profile}. Then press Enter.",
  skip_if: -> { File.exist?(env_output_path) },
) do
  execute "generate ai-memory .env" do
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
  notifies :run, "execute[restart memory]"
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
execute "fetch apm-server CA cert for ai-memory auth-proxy" do
  command "aws ssm get-parameter --name /monitoring/apm/ca/cert " \
          "--profile #{aws_profile} --region #{aws_region} " \
          "--query Parameter.Value --output text > #{apm_ca_path} && " \
          "chmod 0644 #{apm_ca_path}"
  user node[:setup][:user]
  not_if "test -f #{apm_ca_path}"
  notifies :run, "execute[restart memory]"
end

# Ensure pgvector extension exists on Aurora (uses ephemeral postgres container).
# Marker file replaces the previous unguarded `docker run psql` which fired
# every mitamae run (network round-trip + container pull). The OR-fallthrough
# in the command makes `CREATE EXTENSION IF NOT EXISTS` itself idempotent;
# the marker ensures we don't pay the network cost after first success.
#
# Migration: existing hosts with the extension already enabled should
#   touch ~/deploy/memory/.pgvector-enabled
# before the next mitamae run.
pgvector_marker = "#{deploy_dir}/.pgvector-enabled"
execute "enable pgvector extension on Aurora" do
  command %W[
    docker run --rm --env-file #{deploy_dir}/.env
    postgres:16-alpine
    sh -c 'psql "$DATABASE_URL" -c "CREATE EXTENSION IF NOT EXISTS vector;"' && touch #{pgvector_marker}
  ].join(" ")
  user node[:setup][:user]
  not_if "test -f #{pgvector_marker}"
  # Skip when .env was not generated (SSM auth absent / non-interactive
  # bootstrap). `docker run --env-file` aborts with exit 125 when the
  # file is missing.
  only_if "test -f #{env_output_path}"
end

# Compose orchestration via the compose_service DSL
# (cookbooks/functions/default.rb). Emits `ensure memory running` and
# `restart memory` resources — project_name defaults to File.basename(deploy_dir)
# = "memory" (the docker compose project label, not the logical service name).
# Notify targets above must match the emitted resource name.
# `build_flag: false` because the compose
# spec uses ghcr.io/mem0ai/openmemory-mcp pre-built images for openmemory
# itself (auth-proxy still builds lazily via `docker compose up`'s implicit
# build-on-first-run behaviour), and `wait: true` because openmemory-api
# pgvector connectivity setup outlasts `up -d`'s default return point.
compose_service "ai-memory" do
  compose_path "#{deploy_dir}/docker-compose.yml"
  deploy_dir deploy_dir
  env_path env_output_path
  build_flag false
  wait true
end
