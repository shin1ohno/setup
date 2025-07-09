# frozen_string_literal: true

# Claude Code is Anthropic's agentic coding tool for the terminal
# It requires Node.js to run as it's distributed via npm

# Ensure Node.js is installed via volta
include_cookbook "nodejs"

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

# Create config directory if it doesn't exist
directory "#{ENV['HOME']}/.config/claude-code" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end
