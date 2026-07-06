# frozen_string_literal: true
#
# local-es-memory — single-node ElasticSearch (Docker) + memory-v2 MCP for this
# MacBook Air. Replaces the retired ~/deploy/local-mcp stack (cognee + mem0 +
# postgres + qdrant) with the SAME memory-v2 backend the hosted es-memory LXC
# runs (BM25 + dense_vector kNN on ES, Voyage embeddings). darwin-only.
#
# The 5 memory-mcp modules under files/mcp/ (server/es_backend/voyage/scoring/
# identity) + requirements-v2.txt are VERBATIM copies of
# cookbooks/lxc-es-memory/files/memory-mcp/ — bin/lint-cookbooks enforces
# byte-equality so a server-side contract change can't silently diverge here.
#
# Unlike the LXC (native systemd + venv, no docker per the PVE design gate), this
# is all-in-docker-compose: Docker Desktop is already the runtime on macOS and a
# single compose keeps ops simple (the user's explicit ask). No OIDC/JWT proxy —
# loopback single-user; provenance comes from static X-Verified-* headers set at
# Claude Code registration below.

return unless node[:platform] == "darwin"

home  = node[:setup][:home]
user  = node[:setup][:user]

deploy_dir   = "#{home}/deploy/local-es-memory"
compose_path = "#{deploy_dir}/docker-compose.yml"
env_path     = "#{deploy_dir}/.env"

aws_region  = "ap-northeast-1"
aws_profile = "default" # see files/generate_env.sh header (pve-bootstrap-ssm token is stale on this Mac)

claude_bin = "#{home}/.local/bin/claude"
mcp_url    = "http://127.0.0.1:8010/memory/mcp"

# --------------------------------------------------------------------------- #
# Deploy dir + compose context (compose.yml / Dockerfiles / mcp modules)
# All user-space (~/deploy) — no owner/group set (defaults to the apply user;
# avoids the mitamae sudo-chown trap, see ~/.claude/rules/ruby.md).
# --------------------------------------------------------------------------- #
directory "#{home}/deploy" do
  mode "755"
end

[deploy_dir, "#{deploy_dir}/es", "#{deploy_dir}/mcp"].each do |d|
  directory d do
    mode "755"
    action :create
  end
end

remote_file compose_path do
  source "files/docker-compose.yml"
  mode "644"
  notifies :run, "execute[restart local-es-memory]"
end

remote_file "#{deploy_dir}/es/Dockerfile" do
  source "files/es/Dockerfile"
  mode "644"
  notifies :run, "execute[restart local-es-memory]"
end

remote_file "#{deploy_dir}/mcp/Dockerfile" do
  source "files/mcp/Dockerfile"
  mode "644"
  notifies :run, "execute[restart local-es-memory]"
end

%w[server.py es_backend.py voyage.py scoring.py identity.py requirements-v2.txt].each do |f|
  remote_file "#{deploy_dir}/mcp/#{f}" do
    source "files/mcp/#{f}"
    mode "644"
    notifies :run, "execute[restart local-es-memory]"
  end
end

# --------------------------------------------------------------------------- #
# .env (docker-compose var source) — VOYAGE_API_KEY from SSM
# --------------------------------------------------------------------------- #
generated_dir = "#{node[:setup][:root]}/generated"
directory node[:setup][:root] do
  mode "755"
end
directory generated_dir do
  mode "755"
end

generate_env_script = File.join(File.dirname(__FILE__), "files", "generate_env.sh")
env_temp_path = "#{generated_dir}/local-es-memory.env"

# Gate matches the generator's actual profile (default). Content-aware skip_if
# (grep VOYAGE_API_KEY), not File.exist? — a key rotation must not be a silent
# no-op on a host whose .env predates it.
require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /memory/voyage-api-key SSM param",
  check_command: "aws ssm get-parameter --name /memory/voyage-api-key " \
                 "--profile #{aws_profile} --region #{aws_region} > /dev/null 2>&1",
  instructions: "Run `aws login` (or `aws configure --profile #{aws_profile}`) so " \
                "'#{aws_profile}' has ssm:GetParameter on /memory/voyage-api-key in " \
                "#{aws_region}. Then press Enter.",
  skip_if: -> { File.exist?(env_path) && File.read(env_path).include?("VOYAGE_API_KEY") },
) do
  execute "generate local-es-memory .env" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "bash #{generate_env_script} #{env_temp_path}"
    user user
  end
end

# Place the .env (converge-time only_if, not compile-time File.exist? — see
# ~/.claude/rules/ruby.md mitamae evaluation model).
remote_file env_path do
  source env_temp_path
  mode "600"
  notifies :run, "execute[restart local-es-memory]"
  only_if "test -f #{env_temp_path}"
end

file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path}"
end

# --------------------------------------------------------------------------- #
# Bring up the stack (ES + memory-mcp). compose_service gives the idempotent
# `ensure local-es-memory running` (up -d --build) + notify-driven
# `restart local-es-memory` (up -d --build --force-recreate). --wait blocks on
# the ES healthcheck so the MCP dep starts only once ES is reachable.
# --------------------------------------------------------------------------- #
compose_service "local-es-memory" do
  compose_path compose_path
  deploy_dir deploy_dir
  env_path env_path
  user user
  wait true
  wait_timeout 300
end

# --------------------------------------------------------------------------- #
# Claude Code MCP registration (loopback, static provenance headers, no proxy)
# --------------------------------------------------------------------------- #

# Retire the stale local-mcp registrations (dead :8002 cognee / :8765 mem0). The
# memory-local removal is scoped to the OLD :8765 endpoint so a re-apply does NOT
# tear down the new :8010 entry created below.
execute "remove stale MCP cognee-local" do
  command "#{claude_bin} mcp remove -s user cognee-local >/dev/null 2>&1 || " \
          "#{claude_bin} mcp remove cognee-local >/dev/null 2>&1 || true"
  user user
  only_if "test -x #{claude_bin} && #{claude_bin} mcp list 2>/dev/null | grep -q '^cognee-local:'"
end

execute "remove stale memory-local (old :8765)" do
  command "#{claude_bin} mcp remove -s user memory-local >/dev/null 2>&1 || " \
          "#{claude_bin} mcp remove memory-local >/dev/null 2>&1 || true"
  user user
  only_if "test -x #{claude_bin} && #{claude_bin} mcp list 2>/dev/null | grep -E '^memory-local:' | grep -q '8765'"
end

# Register memory-local -> local ES memory-v2. Static X-Verified-* headers let
# the server stamp provenance and pass destructive-op authz over loopback
# (server.py trusts these headers; the proxy that would normally inject them is
# omitted for a single-user local store).
execute "register memory-local MCP" do
  # NOTE: name + url MUST precede --header. `-H/--header` is a VARIADIC option
  # (`<header...>`) in the claude CLI — placed before the positionals it swallows
  # `memory-local` and the url as header values ("missing required argument
  # 'name'"). This ordering matches `claude mcp add --help`.
  command "#{claude_bin} mcp add -s user --transport http memory-local #{mcp_url} " \
          "--header 'X-Verified-Sub: shin1ohno@gmail.com' " \
          "--header 'X-Verified-Grant: authorization_code'"
  user user
  only_if "test -x #{claude_bin}"
  not_if "#{claude_bin} mcp list 2>/dev/null | grep -qF '#{mcp_url}'"
end
