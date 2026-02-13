# frozen_string_literal: true

# Claude Code is Anthropic's agentic coding tool for the terminal
# Installed via native installer (https://code.claude.com/docs/en/setup)

include_cookbook "mcp"

claude_path = "#{ENV["HOME"]}/.local/bin/claude"

# Uninstall Claude Code from mise if previously installed
execute "uninstall claude-code from mise" do
  user node[:setup][:user]
  command "$HOME/.local/bin/mise uninstall --all npm:@anthropic-ai/claude-code"
  only_if "$HOME/.local/bin/mise list 2>/dev/null | grep -q 'npm:@anthropic-ai/claude-code'"
end

# Uninstall Claude Code from npm if previously installed
execute "uninstall claude-code from npm" do
  user node[:setup][:user]
  command "npm uninstall -g @anthropic-ai/claude-code"
  only_if "npm list -g @anthropic-ai/claude-code 2>/dev/null | grep -q '@anthropic-ai/claude-code'"
end

# Install Claude Code via native installer
execute "install claude-code via native installer" do
  user node[:setup][:user]
  command "curl -fsSL https://claude.ai/install.sh | bash"
  not_if "test -f #{claude_path}"
end

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
