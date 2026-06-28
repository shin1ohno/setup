# frozen_string_literal: true

# es-memory-mcp — unified Cognee + Mem0 MCP server backed by the ElasticSearch
# cluster (es-0/1/2). Replaces the Cognee (RDS pgvector / kuzu) and Mem0
# (Qdrant / Aurora pgvector) storage stacks with BM25 + dense_vector kNN
# hybrid search on the existing 3-node ES cluster (basic license, no ML —
# embeddings computed externally via OpenAI text-embedding-3-small).
#
# Serves two MCP namespaces on one upstream so the existing claude.ai
# connector tool names (mcp__claude_ai_cognee__*, mcp__claude_ai_ai_memory__*)
# are preserved 1:1:  /cognee/mcp and /memory/mcp, each behind its own
# SAGE-JWT auth proxy (reused verbatim from cookbooks/lxc-memory).
#
# Requires docker-engine cookbook to be included before this cookbook.

return if node[:platform] == "darwin"

include_cookbook "awscli"

# Pin the scoped fleet AWS profile (pve-bootstrap-ssm) so the auth gate and the
# .env generator target the same IAM principal — see CLAUDE.md "Auth-check gate
# must match the cookbook's actual invocation profile".
ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

deploy_dir = "#{node[:setup][:home]}/deploy/es-memory"

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
  notifies :run, "execute[restart es-memory]"
end

# es-memory-mcp server build context
mcp_dir = "#{deploy_dir}/es-memory-mcp"
directory mcp_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w[Dockerfile requirements.txt es_backend.py server.py].each do |f|
  remote_file "#{mcp_dir}/#{f}" do
    source "files/es-memory-mcp/#{f}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    notifies :run, "execute[restart es-memory]"
  end
end

# Auth proxy build context (one image, two compose services with different
# PATH_PREFIX / PORT env — see docker-compose.yml).
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
    notifies :run, "execute[restart es-memory]"
  end
end

# Standalone ES index templates + setup script (the server self-bootstraps
# indices on startup; these are kept for manual ops / migration use).
es_indices_dir = "#{deploy_dir}/es-indices"
directory es_indices_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w[knowledge.json memory-user.json setup_indices.sh].each do |f|
  remote_file "#{es_indices_dir}/#{f}" do
    source "files/es-indices/#{f}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode(f.end_with?(".sh") ? "755" : "644")
    notifies :run, "execute[restart es-memory]"
  end
end

# Generate .env with secrets from SSM Parameter Store. Gate on the ES password
# path (/monitoring/* is in the pve-bootstrap-ssm grant) — a representative
# read that fails if the profile lacks SSM access.
generated_dir = "#{node[:setup][:root]}/generated"
directory node[:setup][:root] do
  mode "755"
end
directory generated_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

generate_env_script = File.join(File.dirname(__FILE__), "files", "generate_env.sh")
env_temp_path = "#{generated_dir}/es-memory.env"
env_output_path = "#{deploy_dir}/.env"

require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /monitoring/elastic/* + /mcp/* SSM params",
  check_command: "aws ssm get-parameter --name /monitoring/elastic/elastic-password " \
                 "--profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on " \
                "/monitoring/elastic/* and /mcp/openai-api-key in #{aws_region}. " \
                "On a fresh machine: aws configure --profile #{aws_profile}. " \
                "Then press Enter.",
  skip_if: -> { File.exist?(env_output_path) },
) do
  execute "generate es-memory .env" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "bash #{generate_env_script} #{env_temp_path}"
    user node[:setup][:user]
  end
end

# Deploy + clean up at converge time (converge-time only_if, not compile-time
# File.exist? — see ~/.claude/rules/ruby.md mitamae evaluation model).
remote_file env_output_path do
  source env_temp_path
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "600"
  notifies :run, "execute[restart es-memory]"
  only_if "test -f #{env_temp_path}"
end

file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path}"
end

# Compose orchestration via the compose_service DSL. Emits
# `ensure es-memory running` + `restart es-memory`. build_flag true because all
# three services build from local context; buildkit false because BuildKit's
# mount namespacing trips up in an unprivileged PVE LXC even with
# features_nesting=true (see ~/.claude/rules/pve-lxc.md + lxc-consent); wait
# true so the MCP server's ES index bootstrap completes before returning.
compose_service "es-memory" do
  compose_path "#{deploy_dir}/docker-compose.yml"
  deploy_dir deploy_dir
  env_path env_output_path
  buildkit false
  build_flag true
  wait true
end
