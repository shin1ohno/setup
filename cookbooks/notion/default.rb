# frozen_string_literal: true

# Notion - note-taking and collaboration platform
# This cookbook installs the Notion app, the ncli CLI wrapper for Notion's
# Remote MCP, and the Claude Code "notion" skill.
#
# The hosted Notion MCP is consumed via a claude.ai connector (configured in
# the Claude.ai connectors UI), NOT a user-scope CLI server. This cookbook
# therefore does NOT run `claude mcp add notion`: registering a user-scope
# server only produced an unauthenticated duplicate sitting alongside the
# already-working connector.

include_cookbook "mise"

# Install Notion app via Homebrew Cask (macOS only).
# `install --cask --adopt` (not `reinstall`): on a Mac where Notion was
# installed manually, /Applications/Notion.app already exists and is NOT
# brew-managed, so the `brew list | fgrep -q notion` guard does not skip and
# `brew reinstall` aborts with "It seems there is already an App at
# '/Applications/Notion.app'". `--adopt` brings the existing app under brew
# management without re-downloading; on a clean Mac it installs normally.
if node[:platform] == "darwin"
  execute "brew install --cask --adopt notion" do
    not_if "brew list | fgrep -q notion"
  end
end

# Install ncli (CLI wrapper for Notion Remote MCP) via mise npm backend.
# Source: https://github.com/nyosegawa/notion-cli  (npm: @sakasegawa/ncli)
execute "$HOME/.local/bin/mise install npm:@sakasegawa/ncli@latest" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list npm:@sakasegawa/ncli | grep -q '@sakasegawa/ncli'"
end

execute "$HOME/.local/bin/mise use --global npm:@sakasegawa/ncli@latest" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list npm:@sakasegawa/ncli | grep -q '\\* '"
end

# The "notion" skill resources below use `only_if "test -f #{claude_path}"`
# so the claude-binary check happens at converge time — on a clean run the
# claude-code cookbook's mise install populates the binary before we get
# here. A compile-time `if File.exist?(claude_path)` wrapper would evaluate
# before any execute had run, skipping the block on clean runs.
claude_path = "#{node[:setup][:home]}/.local/bin/claude"

# Deploy the upstream "notion" skill (vendored from
# nyosegawa/notion-cli@a325ac7a, v0.3.3). The skill drives ncli usage from
# Claude Code; it requires `ncli login` (OAuth) and optionally
# `ncli rest login` (integration token) as one-time manual steps.
skill_dir = "#{node[:setup][:home]}/.claude/skills/notion"

directory skill_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
  only_if "test -f #{claude_path}"
end

remote_file "#{skill_dir}/SKILL.md" do
  source "files/skills/notion/SKILL.md"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  action :create
  only_if "test -f #{claude_path}"
end

directory "#{skill_dir}/references" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
  only_if "test -f #{claude_path}"
end

%w(command-reference.md id-patterns.md).each do |file_name|
  remote_file "#{skill_dir}/references/#{file_name}" do
    source "files/skills/notion/references/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
    only_if "test -f #{claude_path}"
  end
end

# Operator hint when claude binary is missing (claude-code cookbook
# disabled or install failed earlier in the run).
local_ruby_block "log notion claude-missing hint" do
  block { MItamae.logger.info "Claude Code is not installed, skipping Notion MCP and skill configuration" }
  not_if "test -f #{claude_path}"
end
