# frozen_string_literal: true

# Claude Code is Anthropic's agentic coding tool for the terminal
# Installed via mise npm backend

# Ensure mise and Node.js are installed
include_cookbook "mise"
include_cookbook "nodejs"
include_cookbook "mcp"

# Install Claude Code using mise npm backend
execute "$HOME/.local/bin/mise install npm:@anthropic-ai/claude-code@latest" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list npm:@anthropic-ai/claude-code | grep -q '@anthropic-ai/claude-code'"
end

# Set Claude Code as globally available via mise shims
execute "$HOME/.local/bin/mise use --global npm:@anthropic-ai/claude-code@latest" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list npm:@anthropic-ai/claude-code | grep -q '\\* '"
end

# Add Claude Code to the profile
add_profile "claude-code" do
  bash_content <<~BASH
    # Claude Code - Anthropic's AI coding assistant
    export CLAUDE_CODE_HOME="$HOME/.config/claude-code"
    alias claude="$HOME/.local/share/mise/shims/claude"

    # Add Claude Code auto-completion
    if [ -f "$HOME/.config/claude-code/claude_completion.sh" ]; then
      source "$HOME/.config/claude-code/claude_completion.sh"
    fi
  BASH
  fish_content <<~FISH
    # Claude Code - Anthropic's AI coding assistant
    set -gx CLAUDE_CODE_HOME $HOME/.config/claude-code
    alias claude="$HOME/.local/share/mise/shims/claude"
    # Add Claude Code auto-completion
    if test -f "$HOME/.config/claude-code/claude_completion.fish"
      source "$HOME/.config/claude-code/claude_completion.fish"
    end
  FISH
end

claude_path = "#{ENV["HOME"]}/.local/share/mise/shims/claude"

execute "mcp setup" do
  not_if "#{claude_path} mcp list | grep -q o3"
  command <<~BASH
    #{claude_path} mcp add o3-high -s user -e SEARCH_CONTEXT_SIZE=high -e REASONING_EFFORT=high -- npx o3-search-mcp
    #{claude_path} mcp add o3 -s user -e SEARCH_CONTEXT_SIZE=medium -e REASONING_EFFORT=medium -- npx o3-search-mcp
    #{claude_path} mcp add o3-low -s user -e SEARCH_CONTEXT_SIZE=low -e REASONING_EFFORT=low -- npx o3-search-mcp
  BASH
end

directory "#{ENV["HOME"]}/.claude" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w(CLAUDE.md settings.json).each do |file_name|
  remote_file "#{ENV["HOME"]}/.claude/#{file_name}" do
    source "files/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end

remote_file "#{ENV["HOME"]}/.claude-agents.json" do
  source "files/claude-agents.json"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  action :create
end
