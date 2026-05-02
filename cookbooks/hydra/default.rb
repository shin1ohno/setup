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
require_external_auth(
  tool_name: "AWS CLI (for /hydra/* SSM params)",
  check_command: "aws sts get-caller-identity",
  instructions: "On a fresh machine: aws configure (or aws configure --profile <name> + export AWS_PROFILE=<name>). Then press Enter to retry.",
  skip_if: -> { File.exist?(env_output_path) },
) do
  execute "generate hydra .env" do
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
  notifies :run, "execute[docker compose restart hydra]"
  only_if "test -f #{env_temp_path}"
end

file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path}"
end

# Resources below require .env in place. Each only_if shell guard runs at
# converge time so they fire on the same run that generated .env (a previous
# compile-time `if File.exist?(env_output_path)` wrapper skipped declaration
# on clean runs).
#
# Create hydra database on Aurora (uses ephemeral postgres container).
# not_if uses a marker file rather than re-querying Aurora every run —
# the previous `docker run --rm postgres:16-alpine sh -c 'psql ...'` not_if
# took 5–30s on warm runs and could hang indefinitely if Aurora was
# unreachable. The marker is touched only on successful CREATE DATABASE
# (or on the OR-fallthrough when the DB already exists), so a transient
# failure does not falsely permanent-skip the resource.
#
# Migration: existing hosts with the DB already created should
#   touch ~/deploy/hydra/.hydra-db-created
# before the next mitamae run.
db_marker = "#{deploy_dir}/.hydra-db-created"
execute "create hydra database on Aurora" do
  command %W[
    docker run --rm --env-file #{deploy_dir}/.env
    postgres:16-alpine
    sh -c 'psql "postgresql://hydra:${HYDRA_PASSWORD}@${AURORA_ENDPOINT}:5432/postgres?sslmode=require"
    -c "SELECT 1 FROM pg_database WHERE datname = '"'"'hydra'"'"'" | grep -q 1 ||
    psql "postgresql://hydra:${HYDRA_PASSWORD}@${AURORA_ENDPOINT}:5432/postgres?sslmode=require"
    -c "CREATE DATABASE hydra;"' && touch #{db_marker}
  ].join(" ")
  user node[:setup][:user]
  only_if "test -f #{env_output_path} && ! test -f #{db_marker}"
end

compose_path = "#{deploy_dir}/docker-compose.yml"

# Ensure containers are running. `docker compose ps --filter` is unusably
# slow (timeouts >60s on this host), so we resolve "running" state via
# `docker ps` with the compose-project label — fast and unaffected by
# compose env-var expansion. Excludes hydra-migrate (one-shot migration
# job that exits on success). Fires when any of {hydra, consent} is not
# in a running state.
project_name = File.basename(deploy_dir)
execute "ensure hydra running" do
  command "docker compose -f #{compose_path} up -d --build"
  user node[:setup][:user]
  only_if <<~SH.tr("\n", " ").strip
    test -f #{env_output_path} || exit 1;
    running=$(docker ps --filter "label=com.docker.compose.project=#{project_name}"
                        --filter status=running --format '{{.Label "com.docker.compose.service"}}'
              | grep -v '^hydra-migrate$' | sort | tr '\\n' ' ');
    test "$running" = "consent hydra " && exit 1 || exit 0
  SH
end

# Operator hint when .env isn't generated yet (e.g. SSM params not registered).
local_ruby_block "log hydra setup hint" do
  block { MItamae.logger.info "hydra: .env not found — run ~/deploy/hydra/setup-hydra.sh first, then re-run mitamae" }
  not_if { File.exist?(env_output_path) }
end

# Recreate containers when compose config or built image sources change.
# Notified by remote_file resources above; no-op otherwise.
# Defined unconditionally so notifies: resolve even before .env is generated.
execute "docker compose restart hydra" do
  command "docker compose -f #{deploy_dir}/docker-compose.yml up -d --build"
  user node[:setup][:user]
  action :nothing
end
