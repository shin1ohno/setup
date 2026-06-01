# frozen_string_literal: true
#
# local-mcp: fully-local Cognee + OpenMemory MCP on the MacBook Air.
#
# Air runs its OWN cognee + openmemory with independent local data (NOT the
# home Aurora/RDS). All MCP ports bind to 127.0.0.1, so Claude Code on the same
# host connects over loopback (no network exposure, no app-layer auth).
#
#   cognee-local -> http://127.0.0.1:8002/mcp   (mcp__cognee-local__*)
#   memory-local -> http://127.0.0.1:8765/mcp   (mcp__memory-local__*)
#
# Read/write split: the hosted mcp.ohno.be connectors stay ENABLED for reads;
# their WRITE tools are denied via Claude Code permissions (Air-only union-merge
# into ~/.claude/settings.json at the bottom of this recipe), so writes go to
# the local servers and reads can use either.
#
# Data persists in named docker volumes (pg_data/qdrant_data/cognee_data/
# cognee_system). `docker compose down` keeps them; NEVER `down -v`.
#
# Gated to darwin + Air only (cookbooks/macos-hub idiom). Heavy on a laptop —
# see files/docker-compose.yml header for arm64 + Docker Desktop memory notes.

return unless node[:platform] == "darwin"

HOSTNAME_TO_HOST = {
  "xmhtm6qvqx" => "air", # MacBook Air
}.freeze

current_host = run_command("hostname -s").stdout.strip.downcase
if HOSTNAME_TO_HOST[current_host].nil?
  MItamae.logger.warn(
    "local-mcp: hostname '#{current_host}' is not Air — no local MCP stack deployed. " \
    "This cookbook only converges on Air (xmhtm6qvqx).",
  )
  return
end

include_cookbook "awscli"

user  = node[:setup][:user]
group = node[:setup][:group]
home  = node[:setup][:home]

# Same AWS profile/region convention as cookbooks/ssh-keys + cognee + ai-memory
# so the require_external_auth check_command and the .env generator target the
# same IAM principal (per CLAUDE.md "auth-check gate must match invocation").
ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_profile = ssh_keys_config["aws_profile"]
aws_region  = ssh_keys_config["aws_region"]

deploy_dir       = "#{home}/deploy/local-mcp"
patches_dir      = "#{deploy_dir}/patches"
postgres_init_dir = "#{deploy_dir}/postgres-init"

[deploy_dir, patches_dir, postgres_init_dir].each do |dir|
  directory dir do
    owner user
    group group
    mode "755"
    action :create
  end
end

remote_file "#{deploy_dir}/docker-compose.yml" do
  source "files/docker-compose.yml"
  owner user
  group group
  mode "644"
  notifies :run, "execute[restart local-mcp]"
end

# Reused patches (byte-identical copies of cognee/ai-memory patches — see
# files/patches/README.md). The compose mounts these into the containers.
{
  "cognee-mcp-server.py"     => patches_dir,
  "cognee-mcp-client.py"     => patches_dir,
  "openmemory-mcp-server.py" => patches_dir,
  "openmemory-database.py"   => patches_dir,
}.each do |fname, dir|
  remote_file "#{dir}/#{fname}" do
    source "files/patches/#{fname}"
    owner user
    group group
    mode "644"
    notifies :run, "execute[restart local-mcp]"
  end
end

remote_file "#{postgres_init_dir}/01-databases.sql" do
  source "files/postgres-init/01-databases.sql"
  owner user
  group group
  mode "644"
  # No restart notify: this runs only on an empty pg_data volume at container
  # init time; changing it after first boot requires removing the volume.
end

# --- .env generation (LLM/OpenAI keys from SSM; local DB creds are static) ---
generated_dir   = "#{node[:setup][:root]}/generated"
directory generated_dir do
  owner user
  group group
  mode "755"
  action :create
end

generate_env_script = File.join(File.dirname(__FILE__), "files", "generate_env.local.sh")
env_temp_path   = "#{generated_dir}/local-mcp.env"
env_output_path = "#{deploy_dir}/.env"

require_external_auth(
  tool_name: "AWS CLI (profile=#{aws_profile}, region=#{aws_region}) for /cognee/* + /mcp/openai-api-key SSM params",
  check_command: "aws ssm get-parameter --name /cognee/llm-endpoint " \
                 "--profile #{aws_profile} --region #{aws_region} " \
                 "> /dev/null 2>&1",
  instructions: "Configure '#{aws_profile}' with ssm:GetParameter on /cognee/* and " \
                "/mcp/openai-api-key in #{aws_region} (aws configure --profile #{aws_profile}), " \
                "OR skip SSM and run the generator manually with exported keys:\n" \
                "  COGNEE_LLM_API_KEY=sk-... OPENAI_API_KEY=sk-... " \
                "bash #{generate_env_script} #{env_output_path}\n" \
                "Then press Enter.",
  skip_if: -> { File.exist?(env_output_path) },
) do
  execute "generate local-mcp .env" do
    command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
            "bash #{generate_env_script} #{env_temp_path}"
    user user
  end
end

# Deploy + clean up at converge time (only_if guards the clean-run case where
# the generate step was skipped — non-TTY without SSM auth).
remote_file env_output_path do
  source env_temp_path
  owner user
  group group
  mode "600"
  notifies :run, "execute[restart local-mcp]"
  only_if "test -f #{env_temp_path}"
end

file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path}"
end

# --- compose orchestration (cookbooks/functions/default.rb DSL) ---
# build_flag false: every service uses a pulled image (no local Dockerfile).
# wait true + 180s: cognee first-boot alembic migration (slower under arm64
# emulation) outlasts plain `up -d`'s return point.
compose_service "local-mcp" do
  compose_path "#{deploy_dir}/docker-compose.yml"
  deploy_dir deploy_dir
  env_path env_output_path
  build_flag false
  wait true
  wait_timeout 180
end

# --- register local servers with the Claude Code CLI (notion pattern) ---
# user scope -> ~/.claude.json; coexists with the hosted connectors.
claude_path = "#{home}/.local/bin/claude"

execute "register cognee-local mcp for claude code" do
  command "#{claude_path} mcp add -s user --transport http cognee-local http://127.0.0.1:8002/mcp"
  user user
  only_if "test -f #{claude_path}"
  not_if  "#{claude_path} mcp list | grep -q cognee-local"
end

execute "register memory-local mcp for claude code" do
  command "#{claude_path} mcp add -s user --transport http memory-local http://127.0.0.1:8765/mcp"
  user user
  only_if "test -f #{claude_path}"
  not_if  "#{claude_path} mcp list | grep -q memory-local"
end

# --- Air-only read/write split in ~/.claude/settings.json ---
# Deny the hosted-connector WRITE tools (writes go local); allow the local
# tools. Union-merge so other keys + the shared claude-code settings survive,
# and re-runs are idempotent. Claude Code precedence is deny > allow, so the
# connector write tools that the shared settings.json lists under `allow` are
# overridden here on Air. (NOT placed in cookbooks/claude-code/files/settings.json
# because that file ships to every host — this split must stay Air-only.)
settings_path = "#{home}/.claude/settings.json"

local_ruby_block "Air-only local-mcp read/write split in settings.json" do
  block do
    existing = JSON.parse(File.read(settings_path)) rescue {}
    existing["permissions"] ||= {}
    existing["permissions"]["allow"] ||= []
    existing["permissions"]["deny"]  ||= []

    deny_connector_writes = %w[
      mcp__claude_ai_Cognee__cognify
      mcp__claude_ai_Cognee__save_interaction
      mcp__claude_ai_Cognee__delete
      mcp__claude_ai_Cognee__prune
      mcp__claude_ai_memory__add_memories
      mcp__claude_ai_memory__delete_all_memories
    ]
    allow_local = %w[
      mcp__cognee-local__*
      mcp__memory-local__*
    ]

    existing["permissions"]["deny"]  = (existing["permissions"]["deny"]  | deny_connector_writes)
    existing["permissions"]["allow"] = (existing["permissions"]["allow"] | allow_local)

    File.open(settings_path, "w") { |f| f.write(JSON.pretty_generate(existing) + "\n") }
    File.chmod(0o644, settings_path)
  end
  only_if { File.exist?(settings_path) }
end
