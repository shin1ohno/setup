# frozen_string_literal: true

# Claude Code is Anthropic's agentic coding tool for the terminal
# It requires Node.js to run as it's distributed via npm

# Ensure Node.js is installed via volta
include_cookbook "nodejs"
include_cookbook "mcp"

# Install Claude Code
execute "$HOME/.volta/bin/npm install -g @anthropic-ai/claude-code" do
  not_if "test -e \"$HOME/.volta/bin/claude\""
end

# Add Claude Code to the profile
add_profile "claude-code" do
  bash_content <<~BASH
    # Claude Code - Anthropic's AI coding assistant
    export CLAUDE_CODE_HOME="$HOME/.config/claude-code"
    alias claude="/Users/sh1/.claude/local/claude"

    # Add Claude Code auto-completion
    if [ -f "$HOME/.config/claude-code/claude_completion.sh" ]; then
      source "$HOME/.config/claude-code/claude_completion.sh"
    fi
  BASH
  fish_content <<~FISH
    # Claude Code - Anthropic's AI coding assistant
    set -gx CLAUDE_CODE_HOME $HOME/.config/claude-code
    alias claude="/Users/sh1/.claude/local/claude"
    # Add Claude Code auto-completion
    if test -f "$HOME/.config/claude-code/claude_completion.fish"
      source "$HOME/.config/claude-code/claude_completion.fish"
    end
  FISH
end

execute "mcp setup" do
  not_if "claude mcp list | grep -q o3"
  command <<~BASH
    claude mcp add o3-high -s user -e SEARCH_CONTEXT_SIZE=high -e REASONING_EFFORT=high -- npx o3-search-mcp
    claude mcp add o3 -s user -e SEARCH_CONTEXT_SIZE=medium -e REASONING_EFFORT=medium -- npx o3-search-mcp
    claude mcp add o3-low -s user -e SEARCH_CONTEXT_SIZE=low -e REASONING_EFFORT=low -- npx o3-search-mcp
  BASH
end

# Create config directory if it doesn't exist
directory "#{ENV['HOME']}/.claude" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w(CLAUDE.md settings.json).each do |file_name|
  remote_file "#{ENV['HOME']}/.claude/#{file_name}" do
    source "files/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end
