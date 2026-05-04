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
  notifies :run, "execute[docker compose restart ai-memory]"
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
    notifies :run, "execute[docker compose restart ai-memory]"
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

require_external_auth(
  tool_name: "AWS CLI (for /ai-memory/* SSM params)",
  check_command: "aws sts get-caller-identity",
  instructions: "On a fresh machine: aws configure (or aws configure --profile <name> + export AWS_PROFILE=<name>). Then press Enter to retry.",
  skip_if: -> { File.exist?(env_output_path) },
) do
  execute "generate ai-memory .env" do
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
  notifies :run, "execute[docker compose restart ai-memory]"
  only_if "test -f #{env_temp_path}"
end

file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path}"
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

compose_path = "#{deploy_dir}/docker-compose.yml"

# Ensure containers are running. `docker compose ps --filter` is unusably
# slow (>60s timeouts on this host); we resolve "running" state via
# `docker ps` with the compose-project label instead.
project_name = File.basename(deploy_dir)
execute "ensure ai-memory running" do
  command "docker compose -f #{compose_path} up -d --wait --wait-timeout 120"
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
execute "docker compose restart ai-memory" do
  command "docker compose -f #{compose_path} up -d --wait --wait-timeout 120"
  user node[:setup][:user]
  action :nothing
  # Skip when .env was not generated (SSM auth absent / non-interactive
  # bootstrap). Restart would otherwise start containers with empty
  # credentials and fail at runtime.
  only_if "test -f #{env_output_path}"
end
