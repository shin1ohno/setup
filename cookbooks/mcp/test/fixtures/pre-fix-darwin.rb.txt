# frozen_string_literal: true
#
# mcp (macOS): two independent renders of files/servers.yml.
#
#   - Claude Desktop's claude_desktop_config.json — macOS ONLY, which is why
#     these resources live here. The app has no Linux build, and
#     generate_config.sh hardcodes current_platform="darwin" for that reason.
#   - Claude Code USER scope — every platform, so it lives in register.rb and is
#     included from inside the shared auth gate below (linux.rb includes the
#     same file).
#
# Prerequisites (nodejs/awscli/yq/jq + the npm MCP binaries) are in common.rb.

include_recipe "common"

claude_desktop_config_dir = "#{node[:setup][:home]}/Library/Application Support/Claude"

directory claude_desktop_config_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

# Create generated directory for temporary files
generated_dir = "#{node[:setup][:root]}/generated"
directory generated_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

yaml_path = File.join(File.dirname(__FILE__), "files", "servers.yml")
generator_script = File.join(File.dirname(__FILE__), "files", "generate_config.sh")
temp_path = "#{generated_dir}/claude_desktop_config.json"
output_path = "#{claude_desktop_config_dir}/claude_desktop_config.json"

# Both darwin renders resolve /mcp/* SSM parameters (the Desktop config and
# the darwin-side register both fetch the obsidian key), so one gate covers
# them. Block here until AWS auth is in place — interactive pause + re-check
# loop; a non-TTY host warns and skips instead. linux.rb deliberately has NO
# gate: its render resolves zero SSM parameters (the only ssm: server is
# darwin-pinned), so this gate is darwin-only by design (2026-08 gap decision).
require_external_auth(
  tool_name: "AWS CLI (for MCP server SSM params)",
  # Probe the ACTUAL SSM path the generators read (/mcp/obsidian-api-key) so the
  # gate fails when this identity lacks SSM access. `aws sts get-caller-identity`
  # was a false gate — it passes for any valid identity regardless of SSM scope.
  check_command: "aws ssm get-parameter --name /mcp/obsidian-api-key --with-decryption --query Parameter.Value --output text --region ${AWS_REGION:-ap-northeast-1} >/dev/null 2>&1",
  instructions: "On a fresh machine: aws configure (or aws configure --profile <name> + export AWS_PROFILE=<name>). Then press Enter to retry.",
) do
  # Generate config to temporary location in setup root
  execute "generate claude_desktop_config.json" do
    command "bash #{generator_script} #{yaml_path} #{temp_path}"
    user node[:setup][:user]
  end

  include_recipe "register"
end

# Merge managed config into existing file, preserving user-added mcpServers.
# Runs in a local_ruby_block so the merge logic and only_if check both
# evaluate at converge time, after the preceding execute has produced
# temp_path. A bare Ruby `if File.exist?(temp_path)` at recipe-load time
# ran before the execute and skipped declaring the merge on clean runs.
local_ruby_block "merge claude_desktop_config.json" do
  block do
    managed  = JSON.parse(File.read(temp_path))
    existing = File.exist?(output_path) ? (JSON.parse(File.read(output_path)) rescue {}) : {}

    merged_servers = (existing["mcpServers"] || {}).merge(managed["mcpServers"] || {})
    merged = existing.merge(managed)
    merged["mcpServers"] = merged_servers

    File.open(output_path, "w") { |f| f.write(JSON.pretty_generate(merged) + "\n") }
    # 0o600: merged file holds plaintext MCP API keys (matches every other secret file in this repo).
    File.chmod(0o600, output_path)
    File.delete(temp_path)
  end
  only_if { File.exist?(temp_path) }
end

# =============================================================================
# Codex CLI MCP config
# =============================================================================
# MCP servers configuration is generated from files/servers.yml
# The codex-cli cookbook will read the generated config if needed
