# frozen_string_literal: true

include_cookbook "mise"

# Install Codex CLI using mise npm backend
execute "$HOME/.local/bin/mise install npm:@openai/codex@latest" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list npm:@openai/codex | grep -q '@openai/codex'"
end

# Set Codex CLI as globally available
execute "$HOME/.local/bin/mise use --global npm:@openai/codex@latest" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list npm:@openai/codex | grep -q '\\* '"
end

# Ensure ~/.codex directory exists
directory "#{ENV["HOME"]}/.codex" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

# Collect ManagedProjects directories for trust configuration
managed_projects_dir = "#{ENV["HOME"]}/ManagedProjects"
trusted_projects = [ENV["HOME"]]

if Dir.exist?(managed_projects_dir)
  Dir.glob("#{managed_projects_dir}/*").select { |f| File.directory?(f) }.each do |dir|
    trusted_projects << dir
  end
end

# Get MCP servers from node (set by mcp cookbook if included first)
mcp_servers = node[:mcp_servers] || {}

# Deploy codex config.toml
template "#{ENV["HOME"]}/.codex/config.toml" do
  source "templates/config.toml.erb"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  variables(
    trusted_projects: trusted_projects,
    mcp_servers: mcp_servers
  )
end
