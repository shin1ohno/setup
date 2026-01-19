# frozen_string_literal: true

# Ensure Node.js is installed via mise
include_cookbook "nodejs"

# Ensure AWS CLI is available for SSM parameter retrieval
include_cookbook "awscli"

# Ensure yq is available for YAML processing
include_cookbook "yq"

mcp_commands = %w(o3-search-mcp mcp-hub)

mcp_commands.each do |com|
  execute "export PATH=$HOME/.local/share/mise/shims:$PATH && npm install -g #{com}" do
    user node[:setup][:user]
    not_if "export PATH=$HOME/.local/share/mise/shims:$PATH && npm list -g #{com}"
  end
end

# =============================================================================
# Deploy Claude Desktop config (macOS only)
# =============================================================================
if node[:platform] == "darwin"
  claude_desktop_config_dir = "#{ENV["HOME"]}/Library/Application Support/Claude"

  directory claude_desktop_config_dir do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    action :create
  end

  yaml_path = File.join(File.dirname(__FILE__), "files", "servers.yml")
  generator_script = File.join(File.dirname(__FILE__), "files", "generate_config.sh")
  output_path = "#{claude_desktop_config_dir}/claude_desktop_config.json"

  execute "generate claude_desktop_config.json" do
    command "bash #{generator_script} #{yaml_path} #{output_path}"
    user node[:setup][:user]
  end

  file output_path do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
  end
end

# =============================================================================
# Codex CLI MCP config
# =============================================================================
# MCP servers configuration is generated from files/servers.yml
# The codex-cli cookbook will read the generated config if needed
