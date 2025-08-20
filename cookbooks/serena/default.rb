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
file "#{ENV["HOME"]}/.local/bin/serena-mcp-setup" do
  content <<~SCRIPT
    #!/bin/bash
    # Helper script for Serena MCP initial setup and project switching
    # Note: Once configured, use Serena's switch_modes tool for mode changes

    MODE=${1:-onboarding}
    CONTEXT=${2:-ide-assistant-enhanced}
    PROJECT=${3:-$(pwd)}

    echo "Setting up Serena MCP for project: $PROJECT"
    echo "Initial mode: $MODE, Context: $CONTEXT"
    
    # Remove existing Serena MCP configuration
    claude mcp remove serena 2>/dev/null || true
    
    # Add new configuration with specified mode
    claude mcp add serena -- uvx --from git+https://github.com/oraios/serena serena-mcp-server --context "$CONTEXT" --mode "$MODE" --project "$PROJECT"
    
    echo ""
    echo "✅ Serena MCP configured successfully!"
    echo ""
    echo "📝 Mode switching:"
    echo "   Once in Claude Code, use the switch_modes tool to change modes dynamically."
    echo "   No need to restart the MCP server!"
    echo ""
    echo "🔧 Available contexts: ide-assistant-enhanced, desktop-app-enhanced"
    echo "📂 Project: $PROJECT"
  SCRIPT
  mode "0755"
  owner node[:setup][:user]
  group node[:setup][:group]
end

# Add shell profile for Serena commands
add_profile "serena" do
  bash_content <<~BASH
    # Serena MCP project setup helpers
    alias serena-setup='serena-mcp-setup'
    alias serena-setup-ide='serena-mcp-setup onboarding ide-assistant-enhanced'
    alias serena-setup-desktop='serena-mcp-setup onboarding desktop-app-enhanced'
    
    # Quick start for common scenarios
    alias serena-new='serena-mcp-setup onboarding ide-assistant-enhanced'
    alias serena-continue='serena-mcp-setup no-onboarding ide-assistant-enhanced'
    
    # Help command
    serena-help() {
      echo "🚀 Serena MCP Commands:"
      echo ""
      echo "  serena-new        - Start a new project (onboarding mode)"
      echo "  serena-continue   - Continue existing project (no-onboarding mode)"
      echo "  serena-setup      - Custom setup: serena-setup [mode] [context] [project-path]"
      echo ""
      echo "📝 Mode switching in Claude Code:"
      echo "  Use the switch_modes tool to change between:"
      echo "  - onboarding, planning, editing, interactive, no-onboarding"
      echo ""
      echo "🔧 Contexts:"
      echo "  - ide-assistant-enhanced (Claude Code optimized)"
      echo "  - desktop-app-enhanced (Full features)"
    }
  BASH
  priority 70
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
file "#{ENV["HOME"]}/.serena/contexts/ide-assistant-enhanced.yml" do
  content <<~YAML
    description: Claude Code optimized context with mode switching capabilities
    prompt: |
      You are running in enhanced IDE assistant context for Claude Code.
      This context is optimized for Claude Code users who want to seamlessly switch between
      different workflow modes (onboarding → planning → editing → interactive) without
      restarting MCP sessions.

      You have access to mode switching capabilities that allow dynamic workflow transitions:
      - Use switch_modes to change between onboarding, planning, editing, and interactive modes
      - Use get_current_config to check your current mode and tool configuration

      File operations, basic edits and reads, and shell commands are handled by Claude Code's
      internal tools. Use Serena's symbolic tools for efficient code analysis and modification.

    excluded_tools:
      - create_text_file
      - read_file
      - execute_shell_command
      - prepare_for_new_conversation

    included_optional_tools:
      - switch_modes
      - get_current_config

    tool_description_overrides: {}
  YAML
  mode "0644"
  owner node[:setup][:user]
  group node[:setup][:group]
end

# Create desktop app enhanced context
file "#{ENV["HOME"]}/.serena/contexts/desktop-app-enhanced.yml" do
  content <<~YAML
    description: Desktop app context with full tool access and mode switching
    prompt: |
      You are running in enhanced desktop app context with full Serena capabilities.
      This context provides access to all Serena tools including file operations,
      symbolic code analysis, and workflow mode switching.

      You can seamlessly transition between different workflow modes:
      - Onboarding: Initial project understanding and setup
      - Planning: Code analysis and design phase
      - Editing: Active code implementation
      - Interactive: User collaboration mode
      - No-onboarding: Continue previous work

    excluded_tools: []

    included_optional_tools:
      - switch_modes
      - get_current_config

    tool_description_overrides: {}
  YAML
  mode "0644"
  owner node[:setup][:user]
  group node[:setup][:group]
end

MItamae.logger.info "Serena MCP setup completed. Use 'serena-new' to start a new project or 'serena-continue' to resume work."
MItamae.logger.info "Run 'serena-help' for usage information."
