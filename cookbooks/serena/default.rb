# Serena - Powerful coding agent toolkit providing semantic retrieval and editing capabilities
# https://github.com/oraios/serena

# Skip installation if uv is not available
unless run_command("which uv", error: false).exit_status == 0
  MItamae.logger.info "uv is not installed, skipping Serena installation"
  return
end

# Skip installation if claude is not available
unless run_command("which claude", error: false).exit_status == 0
  MItamae.logger.info "Claude Code is not installed, skipping Serena MCP configuration"
  return
end

# Install Serena using uvx
execute "install serena" do
  command "$HOME/.local/bin/uvx --from git+https://github.com/oraios/serena serena --help"
  not_if "$HOME/.local/bin/uvx --from git+https://github.com/oraios/serena serena --help"
  user node[:setup][:user]
end

# Note: Custom contexts are now created as YAML files in ~/.serena/contexts/
# This allows for more control and customization than using the CLI commands

# Add Serena MCP server to Claude Code configuration
execute "add serena mcp to claude code" do
  command <<~CMD
    export PATH=$HOME/.local/share/mise/shims:$PATH && $HOME/.claude/local/claude mcp add serena -- uvx --from git+https://github.com/oraios/serena serena-mcp-server --context ide-assistant-enhanced --mode onboarding --project '$(pwd)'
  CMD
  not_if "export PATH=$HOME/.local/share/mise/shims:$PATH && $HOME/.claude/local/claude mcp list | grep serena"
  user node[:setup][:user]
end

# Create a helper script for Serena MCP initial setup and project switching
remote_file "#{ENV['HOME']}/.local/bin/serena-mcp-setup" do
  source "files/serena-mcp-setup.sh"
  mode "0755"
  owner node[:setup][:user]
  group node[:setup][:group]
end

remote_file "#{node[:setup][:root]}/profile.d/70-serena.sh" do
  source "files/serena.sh"
  mode "0644"
  owner node[:setup][:user]
  group node[:setup][:group]
end

# Create contexts directory for Serena configurations
directory "#{ENV["HOME"]}/.serena" do
  mode "0755"
  owner node[:setup][:user]
  group node[:setup][:group]
end

directory "#{ENV["HOME"]}/.serena/contexts" do
  mode "0755"
  owner node[:setup][:user]
  group node[:setup][:group]
end

# Create Claude Code optimized context with mode switching
remote_file "#{ENV['HOME']}/.serena/contexts/ide-assistant-enhanced.yml" do
  source "files/ide-assistant-enhanced.yml"
  mode "0644"
  owner node[:setup][:user]
  group node[:setup][:group]
end

# Create desktop app enhanced context
remote_file "#{ENV['HOME']}/.serena/contexts/desktop-app-enhanced.yml" do
  source "files/desktop-app-enhanced.yml"
  mode "0644"
  owner node[:setup][:user]
  group node[:setup][:group]
end

MItamae.logger.info "Serena MCP setup completed. Use 'serena-new' to start a new project or 'serena-continue' to resume work."
MItamae.logger.info "Run 'serena-help' for usage information."
