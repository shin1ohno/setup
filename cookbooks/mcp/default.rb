# frozen_string_literal: true

# Ensure Node.js is installed via mise
include_cookbook "nodejs"

# Ensure AWS CLI is available for SSM parameter retrieval
include_cookbook "awscli"

# Ensure yq is available for YAML processing
include_cookbook "yq"

# Ensure jq is available for JSON processing in generate_config.sh
include_cookbook "jq"

%w(mcp-hub mcp-remote).each do |com|
  mise_tool com do
    backend "npm"
  end
end

# =============================================================================
# Deploy Claude Desktop config (macOS only)
# =============================================================================
if node[:platform] == "darwin"
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

  # generate_config.sh fetches MCP server credentials from SSM. Block here
  # until AWS auth is in place — interactive pause + re-check loop.
  require_external_auth(
    tool_name: "AWS CLI (for MCP server SSM params)",
    check_command: "aws sts get-caller-identity",
    instructions: "On a fresh machine: aws configure (or aws configure --profile <name> + export AWS_PROFILE=<name>). Then press Enter to retry.",
  ) do
    # Generate config to temporary location in setup root
    execute "generate claude_desktop_config.json" do
      command "bash #{generator_script} #{yaml_path} #{temp_path}"
      user node[:setup][:user]
    end
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

      File.write(output_path, JSON.pretty_generate(merged) + "\n")
      File.chmod(0o644, output_path)
      File.delete(temp_path)
    end
    only_if { File.exist?(temp_path) }
  end
end

# =============================================================================
# Codex CLI MCP config
# =============================================================================
# MCP servers configuration is generated from files/servers.yml
# The codex-cli cookbook will read the generated config if needed
