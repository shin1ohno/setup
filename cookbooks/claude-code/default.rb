# frozen_string_literal: true

# Claude Code is Anthropic's agentic coding tool for the terminal
# Installed via native installer (https://code.claude.com/docs/en/setup)

# mcp is a per-OS split cookbook (macOS also renders Claude Desktop's config);
# claude-code itself runs on both, so dispatch rather than naming one recipe.
include_platform_cookbook "mcp"

claude_path = "#{node[:setup][:home]}/.local/bin/claude"
profile_dir = "#{node[:setup][:root]}/profile.d"

# Remove legacy profile that aliases claude to mise shim
file "#{profile_dir}/50-claude-code.sh" do
  action :delete
end

# Remove claude-code from mise: global config, install tracking, and installs
mise_installs_toml = "#{node[:setup][:home]}/.local/share/mise/installs/.mise-installs.toml"
execute "remove claude-code from mise" do
  user node[:setup][:user]
  command <<~SH
    $HOME/.local/bin/mise unuse --global "npm:@anthropic-ai/claude-code@latest" 2>/dev/null
    $HOME/.local/bin/mise uninstall --all npm:@anthropic-ai/claude-code 2>/dev/null
    $HOME/.local/bin/mise uninstall --all claude 2>/dev/null
    rm -rf $HOME/.local/share/mise/installs/claude
    rm -rf $HOME/.local/share/mise/installs/npm-anthropic-ai-claude-code
    python3 -c "
import re
f = '#{mise_installs_toml}'
t = open(f).read()
t = re.sub(r'\\[claude\\]\\n(?:(?!\\[)[^\\n]*\\n)*\\n?', '', t)
t = re.sub(r'\\[npm-anthropic-ai-claude-code\\]\\n(?:(?!\\[)[^\\n]*\\n)*\\n?', '', t)
open(f,'w').write(t)
" 2>/dev/null
  SH
  only_if "grep -qE '^\\[claude\\]$|^\\[npm-anthropic-ai-claude-code\\]$' #{mise_installs_toml} 2>/dev/null || grep -q 'claude-code' $HOME/.config/mise/config.toml 2>/dev/null"
end

# Remove claude-code installed as npm global under mise-managed node
execute "remove claude-code from mise node globals" do
  user node[:setup][:user]
  command "find $HOME/.local/share/mise/installs/node -name claude -path '*/bin/claude' -delete 2>/dev/null; rm -rf $HOME/.local/share/mise/installs/node/*/lib/node_modules/@anthropic-ai/claude-code"
  only_if "find $HOME/.local/share/mise/installs/node -name claude -path '*/bin/claude' 2>/dev/null | grep -q claude"
end

# Remove claude-code from volta if previously installed
execute "remove claude-code from volta" do
  user node[:setup][:user]
  command "$HOME/.volta/bin/volta uninstall @anthropic-ai/claude-code 2>/dev/null; rm -f $HOME/.volta/bin/claude"
  only_if "test -f $HOME/.volta/bin/claude"
end

# Install Claude Code via native installer
execute "install claude-code via native installer" do
  user node[:setup][:user]
  command "curl -fsSL https://claude.ai/install.sh | bash"
  not_if "test -f #{claude_path}"
end

directory "#{node[:setup][:home]}/.claude" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

# Register official plugin marketplaces. Idempotent via not_if checking known_marketplaces.json.
# Marketplace registration must precede settings.json deploy so that enabledPlugins entries resolve.
known_marketplaces = "#{node[:setup][:home]}/.claude/plugins/known_marketplaces.json"

execute "register claude-plugins-official marketplace" do
  user node[:setup][:user]
  command "#{claude_path} plugin marketplace add anthropics/claude-plugins-official"
  not_if "test -f #{known_marketplaces} && grep -q claude-plugins-official #{known_marketplaces}"
end

execute "register anthropic-agent-skills marketplace" do
  user node[:setup][:user]
  command "#{claude_path} plugin marketplace add anthropics/skills"
  not_if "test -f #{known_marketplaces} && grep -q anthropic-agent-skills #{known_marketplaces}"
end

execute "register saladdays-skills marketplace" do
  user node[:setup][:user]
  command "#{claude_path} plugin marketplace add saladdays/agent-skills"
  not_if "test -f #{known_marketplaces} && grep -q saladdays-skills #{known_marketplaces}"
end

execute "register openai-codex marketplace" do
  user node[:setup][:user]
  command "#{claude_path} plugin marketplace add openai/codex-plugin-cc"
  not_if "test -f #{known_marketplaces} && grep -q openai-codex #{known_marketplaces}"
end

# crit — local-first code review tool (crit.md). The `crit` binary is installed
# by the crit cookbook (mise ubi); this registers its Claude Code plugin, which
# is enabled via enabledPlugins in files/settings.json (crit@crit).
execute "register crit marketplace" do
  user node[:setup][:user]
  command "#{claude_path} plugin marketplace add tomasz-tomczyk/crit"
  not_if "test -f #{known_marketplaces} && grep -q '\"crit\"' #{known_marketplaces}"
end

# fractal — hierarchical agent loops (plasma.ai). The fractal/wiki CLIs are
# installed by the fractal cookbook (mise pipx); this registers the plasma
# marketplace, whose plugin is enabled via enabledPlugins (fractal@plasma).
execute "register plasma marketplace" do
  user node[:setup][:user]
  command "#{claude_path} plugin marketplace add plasma-ai/plugins"
  not_if "test -f #{known_marketplaces} && grep -q '\"plasma\"' #{known_marketplaces}"
end

include_recipe "instructions.rb"

# Status line: coralline (Powerlevel10k-inspired). Vendored + pinned to commit
# 04808390 (2026-06-14). Local-only renderer (jq + git), no network/API.
# Layout: statusline.sh + themes/<name>.conf under ~/.claude/coralline/, with the
# user config at ~/.claude/coralline.conf. The settings.json statusLine command
# is set below after the merge so the home path is correct per-host.
directory "#{node[:setup][:home]}/.claude/coralline" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

directory "#{node[:setup][:home]}/.claude/coralline/themes" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

remote_file "#{node[:setup][:home]}/.claude/coralline/statusline.sh" do
  source "files/coralline/statusline.sh"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w(claude-coral nord).each do |theme_name|
  remote_file "#{node[:setup][:home]}/.claude/coralline/themes/#{theme_name}.conf" do
    source "files/coralline/themes/#{theme_name}.conf"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end

remote_file "#{node[:setup][:home]}/.claude/coralline.conf" do
  source "files/coralline/coralline.conf"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  action :create
end

# Remove the legacy custom statusline (superseded by coralline above).
file "#{node[:setup][:home]}/.claude/statusline-command.sh" do
  action :delete
end

# Merge managed keys into settings.json, preserving unmanaged keys (e.g. mcpServers)
# Deep-merges `permissions` so machine-specific allow/deny entries are preserved
#
# `model` is deliberately NOT in files/settings.json: the shallow merge below lets
# managed win on every top-level key, so pinning the model here rolls the live
# value back on each apply (2026-09-16: live claude-fable-5-1[1m] vs managed
# claude-fable-5[1m]). Model generation is owned by the live file; re-adding the
# key means chasing it in the cookbook every time the generation changes.
settings_path = "#{node[:setup][:home]}/.claude/settings.json"
managed_file  = File.join(File.dirname(__FILE__), "files", "settings.json")

managed  = JSON.parse(File.read(managed_file))
existing = File.exist?(settings_path) ? (JSON.parse(File.read(settings_path)) rescue {}) : {}

# Shallow merge for all top-level keys (managed wins)
merged = existing.merge(managed)

# Deep merge for permissions: union the allow and deny arrays
if existing.key?("permissions") && managed.key?("permissions")
  %w[allow deny].each do |key|
    existing_entries = existing.dig("permissions", key) || []
    managed_entries  = managed.dig("permissions", key) || []
    merged["permissions"][key] = (existing_entries | managed_entries)
  end
end

# Deep merge for enabledPlugins: preserve plugins enabled OUTSIDE the managed set
# (e.g. the mercari-setup overlay's pjmem, or any manually-enabled plugin) instead
# of clobbering them. The shallow merge above replaces the whole enabledPlugins
# map with the managed one; re-merge so managed entries still win on conflict (the
# managed set stays enforced) while live-only entries survive. Same spirit as the
# permissions union: this map only grows — a plugin is not disabled by removing it
# from the managed set (disable it explicitly if needed).
if existing["enabledPlugins"].is_a?(Hash) && managed["enabledPlugins"].is_a?(Hash)
  merged["enabledPlugins"] = existing["enabledPlugins"].merge(managed["enabledPlugins"])
end

# Status line: force coralline with an absolute, per-host command. The static
# files/settings.json value cannot interpolate $HOME, so set it here so every
# platform resolves the correct home (a Linux path was previously hardcoded).
merged["statusLine"] = {
  "type" => "command",
  "command" => "bash #{node[:setup][:home]}/.claude/coralline/statusline.sh",
  "refreshInterval" => 1,
}

# sensitive: the content is the LIVE file re-merged, and the shallow merge above
# replaces `env` and `hooks` wholesale. A value added to the live `env` (an API
# key set through Claude Code's own settings, say) is therefore dropped on the
# next apply and printed as a `-` line of mitamae's INFO-level diff, and
# unmanaged keys such as mcpServers headers show up as context lines. On
# pro-dev that diff goes into the unattended auto-mitamae runner log
# (bin/lint-cookbooks check 15).
file settings_path do
  content JSON.pretty_generate(merged) + "\n"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  sensitive true
end

# Deploy hook scripts
directory "#{node[:setup][:home]}/.claude/hooks" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

# git-command.rb is not a hook: it is the Bash-command parser that
# pre-commit-test.rb and block-co-authored-by.rb load with require_relative, so
# it ships next to them (listed first, ahead of its users) and is not wired in
# settings.json.
%w(git-command.rb pre-commit-test.rb check-trailing-newline.rb check-whitespace-lines.rb block-co-authored-by.rb post-compact-remind.rb mcp-health-check.rb detect-prose-menu.rb warn-loop-repo-shared-tree.rb warn-untracked-before-pull.rb warn-background-launch-no-progress.rb mirror-file-memory.rb session-ingest.rb).each do |file_name|
  remote_file "#{node[:setup][:home]}/.claude/hooks/#{file_name}" do
    source "files/hooks/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    action :create
  end
end

# PATH-priming shim invoked by every ruby hook in settings.json.
# Claude Code hooks run in a non-interactive shell that bypasses the
# rbenv lazy-load profile, so `ruby` would otherwise be unreachable.
remote_file "#{node[:setup][:home]}/.claude/hooks/ruby-shim" do
  source "files/hooks/ruby-shim"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

# Loop-repo registry consumed by the warn-loop-repo-shared-tree PreToolUse hook.
# Repos listed here share their working tree with an autonomous loop; the hook
# emits a soft reminder to use a worktree for git mutations against them.
remote_file "#{node[:setup][:home]}/.claude/loop-repos.json" do
  source "files/loop-repos.json"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  action :create
end

directory "#{node[:setup][:home]}/.claude/worker-floor" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w(impl.json docs.json).each do |file_name|
  remote_file "#{node[:setup][:home]}/.claude/worker-floor/#{file_name}" do
    source "files/worker-floor/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end

# Deploy workflows (multi-agent orchestration scripts, loaded by name via the Workflow tool)
directory "#{node[:setup][:home]}/.claude/workflows" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w(claude-md-audit.js).each do |file_name|
  remote_file "#{node[:setup][:home]}/.claude/workflows/#{file_name}" do
    source "files/workflows/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end

include_recipe "agents.rb"

include_recipe "skills.rb"

# Worker instruction profiles (~/.agents/profiles, profile-* agents, fixed
# per-profile Codex homes). Default since the pro-dev canary passed 12 of 12
# (docs/runbook/worker-instruction-profiles.md).
include_recipe "worker-profiles.rb"

# Deploy TODO pipeline config (docs/todo-management.md). sources.yaml is the
# managed PERSONAL-source list for /todo-collect; work sources live in the
# unmanaged ~/.claude/todo/sources.local.yaml, merged at runtime by the skill.
# runs/ holds the write-once per-run logs and tmp/ the per-run sweep / config
# hand-off files; `todo_queue.py init` creates them too, but a path the loops
# write into is declared defensively (rules/ruby.md).
%w(todo todo/runs todo/tmp).each do |dir_name|
  directory "#{node[:setup][:home]}/.claude/#{dir_name}" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    action :create
  end
end

remote_file "#{node[:setup][:home]}/.claude/todo/sources.yaml" do
  source "files/todo/sources.yaml"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  action :create
end
