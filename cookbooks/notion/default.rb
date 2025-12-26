# frozen_string_literal: true

# Notion - note-taking and collaboration platform
# This cookbook installs the Notion app and sets up Notion MCP for Claude Code

# Install Notion app via Homebrew Cask (macOS only)
if node[:platform] == "darwin"
  execute "brew reinstall --cask notion" do
    not_if "brew list | fgrep -q notion"
  end
end

# Set up Notion MCP for Claude Code (official hosted version via OAuth)
# This uses Notion's official MCP server at mcp.notion.com
claude_path = "#{ENV["HOME"]}/.claude/local/claude"

execute "setup notion mcp for claude code" do
  command "#{claude_path} mcp add --transport http notion https://mcp.notion.com/mcp"
  not_if "#{claude_path} mcp list | grep -q notion"
end
