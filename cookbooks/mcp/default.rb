# frozen_string_literal: true

# Ensure Node.js is installed via mise
include_cookbook "nodejs"

# Ensure AWS CLI is available for SSM parameter retrieval
include_cookbook "awscli"

# Ensure yq is available for YAML processing
include_cookbook "yq"

mcp_commands = %w(o3-search-mcp mcp-hub)

mcp_commands.each do |com|
  execute "install #{com} via mise" do
    user node[:setup][:user]
    command "$HOME/.local/bin/mise use --global npm:#{com}@latest"
    not_if "$HOME/.local/bin/mise list | grep -q 'npm:#{com}'"
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

  # Generate config to temporary location in setup root
  execute "generate claude_desktop_config.json" do
    command "bash #{generator_script} #{yaml_path} #{temp_path}"
    user node[:setup][:user]
  end

  # Deploy using remote_file to enable diff detection
  remote_file output_path do
    source temp_path
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
  end

  # Clean up temporary file (contains sensitive SSM values)
  file temp_path do
    action :delete
  end
end

# =============================================================================
# Codex CLI MCP config
# =============================================================================
# MCP servers configuration is generated from files/servers.yml
# The codex-cli cookbook will read the generated config if needed
