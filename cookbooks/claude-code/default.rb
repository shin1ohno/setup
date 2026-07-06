# frozen_string_literal: true

# Claude Code is Anthropic's agentic coding tool for the terminal
# Installed via native installer (https://code.claude.com/docs/en/setup)

include_cookbook "mcp"

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

remote_file "#{node[:setup][:home]}/.claude/CLAUDE.md" do
  source "files/CLAUDE.md"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  action :create
end

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

file settings_path do
  content JSON.pretty_generate(merged) + "\n"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
end

# Deploy hook scripts
directory "#{node[:setup][:home]}/.claude/hooks" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w(pre-commit-test.rb check-trailing-newline.rb check-whitespace-lines.rb block-co-authored-by.rb post-compact-remind.rb mcp-health-check.rb detect-prose-menu.rb warn-loop-repo-shared-tree.rb).each do |file_name|
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

# Deploy global rules
directory "#{node[:setup][:home]}/.claude/rules" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w(ruby.md shell.md infrastructure.md aws-iam.md docker-compose.md sub-agents.md git-commit.md mcp-config.md rust.md debugging.md editing.md planning.md adversarial-review.md).each do |file_name|
  remote_file "#{node[:setup][:home]}/.claude/rules/#{file_name}" do
    source "files/rules/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end

# Deploy docs (detail files referenced by CLAUDE.md via @import)
directory "#{node[:setup][:home]}/.claude/docs" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w(knowledge-persistence.md debugging-detail.md infrastructure-detail.md claude-cli-headless.md elasticsearch.md mcp-deployment.md neovim.md release-plz.md tailscale.md weave-protocol.md frontend-dev.md remote-trigger.md cookbook-prs.md mise-migration.md kibana-lens.md ios-build.md data-collection.md ruby-detail.md git-commit-detail.md shell-detail.md sub-agents-detail.md planning-detail.md aws-iam-detail.md pve-lxc-detail.md docker-compose-detail.md ffi-audit.md claude-code-plugins.md adversarial-review-detail.md negative-search-detail.md todo-management.md).each do |file_name|
  remote_file "#{node[:setup][:home]}/.claude/docs/#{file_name}" do
    source "files/docs/#{file_name}"
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

# Deploy agents
directory "#{node[:setup][:home]}/.claude/agents" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w(mitamae-validator.md researcher.md session-retrospective.md claude-docs-researcher.md domain-researcher.md service-health-monitor.md).each do |file_name|
  remote_file "#{node[:setup][:home]}/.claude/agents/#{file_name}" do
    source "files/agents/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end

# Deploy skills
%w(writing interview verify retro research research-domains load-test check-services security-review feature-parity verify-mise-backend bootstrap-docs-hub pr-ci-medic morning-triage self-heal-create self-heal-resolve mcp-auth web-crawl setup-release-plz).each do |skill_name|
  directory "#{node[:setup][:home]}/.claude/skills/#{skill_name}" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    action :create
  end

  remote_file "#{node[:setup][:home]}/.claude/skills/#{skill_name}/SKILL.md" do
    source "files/skills/#{skill_name}/SKILL.md"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end

# Deploy writing skill templates
directory "#{node[:setup][:home]}/.claude/skills/writing/templates" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w(dvq.md rfc.md).each do |file_name|
  remote_file "#{node[:setup][:home]}/.claude/skills/writing/templates/#{file_name}" do
    source "files/skills/writing/templates/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end

# Deploy writing skill personas
directory "#{node[:setup][:home]}/.claude/skills/writing/personas" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w(document-writer.md marginal-utility-editor.md).each do |file_name|
  remote_file "#{node[:setup][:home]}/.claude/skills/writing/personas/#{file_name}" do
    source "files/skills/writing/personas/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end

# Deploy writing skill references (Japanese AI-slop removal)
# Only the 3 reference files ship; references/fixtures/ is test-only and intentionally excluded.
directory "#{node[:setup][:home]}/.claude/skills/writing/references" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w(phrases.md structures.md examples.md).each do |file_name|
  remote_file "#{node[:setup][:home]}/.claude/skills/writing/references/#{file_name}" do
    source "files/skills/writing/references/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end

# Deploy bootstrap-docs-hub skill templates
%w(
  templates
  templates/rules
  templates/skills
  templates/skills/sync-bundled-tools
).each do |dir_name|
  directory "#{node[:setup][:home]}/.claude/skills/bootstrap-docs-hub/#{dir_name}" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    action :create
  end
end

%w(
  templates/README.md.tmpl
  templates/CLAUDE.md.tmpl
  templates/gitignore.tmpl
  templates/rules/communication-style.md
  templates/rules/work-discipline.md
  templates/rules/external-tools.md
  templates/rules/content-freshness.md
  templates/rules/parallel-execution.md
  templates/skills/sync-bundled-tools/SKILL.md
).each do |file_name|
  remote_file "#{node[:setup][:home]}/.claude/skills/bootstrap-docs-hub/#{file_name}" do
    source "files/skills/bootstrap-docs-hub/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end

# Clean up deprecated custom items replaced by official plugins.
# - audit-claudemd skill → claude-md-management@claude-plugins-official
# - code-reviewer agent → pr-review-toolkit@claude-plugins-official
# - security-reviewer agent → pr-review-toolkit@claude-plugins-official
file "#{node[:setup][:home]}/.claude/agents/code-reviewer.md" do
  action :delete
end

file "#{node[:setup][:home]}/.claude/agents/security-reviewer.md" do
  action :delete
end

file "#{node[:setup][:home]}/.claude/skills/audit-claudemd/SKILL.md" do
  action :delete
end

directory "#{node[:setup][:home]}/.claude/skills/audit-claudemd" do
  action :delete
end

# Clean up rules/ files moved to docs/ (or inlined into CLAUDE.md) by #638/#639
# and the rules-diet round 2 (ffi-audit / claude-code-plugins / pve-lxc demoted
# to docs/). mitamae only creates files from the deploy lists above — it never
# prunes entries removed from those lists, so every deployed host keeps loading
# the stale rules/ copies (~128K per session) until they are deleted explicitly.
%w(
  architecture.md
  claude-code-plugins.md
  cookbook-prs.md
  data-collection.md
  ffi-audit.md
  frontend-dev.md
  ios-build.md
  kibana-lens.md
  mise-migration.md
  pve-lxc.md
  remote-trigger.md
  tailscale.md
  weave-protocol.md
  writing.md
).each do |file_name|
  file "#{node[:setup][:home]}/.claude/rules/#{file_name}" do
    action :delete
  end
end

# Clean up docs/ detail files whose content was merged into a sibling doc by
# the rules-diet round 2: claude-code-plugins-detail.md → merged into its parent
# (now docs/claude-code-plugins.md); rust-detail.md → merged into
# docs/release-plz.md#crates-io-token-scopes. Same non-pruning caveat as above.
%w(
  claude-code-plugins-detail.md
  rust-detail.md
).each do |file_name|
  file "#{node[:setup][:home]}/.claude/docs/#{file_name}" do
    action :delete
  end
end

# Clean up the retired knowledge-drain skill. Its only backend (Cognee) was
# retired in #656, which removed the skill source but left the deployed copy
# behind on every host (mitamae never prunes). Its TODO-drain role is
# superseded by the todo-collect / todo-reconcile loops (docs/todo-management.md).
file "#{node[:setup][:home]}/.claude/skills/knowledge-drain/SKILL.md" do
  action :delete
end

directory "#{node[:setup][:home]}/.claude/skills/knowledge-drain" do
  action :delete
end

