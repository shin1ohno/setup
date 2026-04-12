# frozen_string_literal: true

# Ensure Node.js is installed via mise
include_cookbook "nodejs"

# Ensure AWS CLI is available for SSM parameter retrieval
include_cookbook "awscli"

# Ensure yq is available for YAML processing
include_cookbook "yq"

# Ensure jq is available for JSON processing in generate_config.sh
install_package "jq" do
  darwin "jq"
  ubuntu "jq"
  arch "jq"
end

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

  # Generate config to temporary location in setup root
  execute "generate claude_desktop_config.json" do
    command "bash #{generator_script} #{yaml_path} #{temp_path}"
    user node[:setup][:user]
  end

  # Merge managed config into existing file, preserving user-added mcpServers.
  # During --dry-run the execute above is a no-op so temp_path won't exist;
  # during a real run, a generate failure halts execution before reaching here.
  if File.exist?(temp_path)
    managed  = JSON.parse(File.read(temp_path))
    existing = File.exist?(output_path) ? (JSON.parse(File.read(output_path)) rescue {}) : {}

    # Deep-merge mcpServers: keep user-added servers, update managed ones
    merged_servers = (existing["mcpServers"] || {}).merge(managed["mcpServers"] || {})
    merged = existing.merge(managed)
    merged["mcpServers"] = merged_servers

    file output_path do
      content JSON.pretty_generate(merged) + "\n"
      owner node[:setup][:user]
      group node[:setup][:group]
      mode "644"
    end

    # Clean up temporary file (contains sensitive SSM values)
    file temp_path do
      action :delete
    end
  end
end

# =============================================================================
# Codex CLI MCP config
# =============================================================================
# MCP servers configuration is generated from files/servers.yml
# The codex-cli cookbook will read the generated config if needed
