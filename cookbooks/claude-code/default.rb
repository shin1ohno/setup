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

%w(pre-commit-test.rb check-trailing-newline.rb check-whitespace-lines.rb block-co-authored-by.rb post-compact-remind.rb).each do |file_name|
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

# Deploy global rules
directory "#{node[:setup][:home]}/.claude/rules" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w(ruby.md shell.md infrastructure.md aws-iam.md pve-lxc.md docker-compose.md tailscale.md writing.md sub-agents.md git-commit.md remote-trigger.md mcp-config.md rust.md architecture.md data-collection.md debugging.md claude-code-plugins.md editing.md frontend-dev.md mise-migration.md ios-build.md weave-protocol.md planning.md ffi-audit.md adversarial-review.md cookbook-prs.md kibana-lens.md).each do |file_name|
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

%w(knowledge-persistence.md).each do |file_name|
  remote_file "#{node[:setup][:home]}/.claude/docs/#{file_name}" do
    source "files/docs/#{file_name}"
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

%w(mitamae-validator.md researcher.md session-retrospective.md claude-docs-researcher.md domain-researcher.md).each do |file_name|
  remote_file "#{node[:setup][:home]}/.claude/agents/#{file_name}" do
    source "files/agents/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end

# Deploy skills
%w(writing interview verify retro research research-domains load-test check-services ingest-batch security-review verify-cognee verify-data-integrity feature-parity verify-mise-backend bootstrap-docs-hub).each do |skill_name|
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

# Deploy Google Workspace CLI (gws) skills — upstream set from
# github.com/googleworkspace/cli (gws v0.22.5). 95 doc-only skills, one
# SKILL.md per directory: gws-* hubs + sub-skills, persona-* role guides,
# recipe-* task recipes. All require the `gws` binary (cookbooks/gws,
# roles/extras) and read gws-shared/SKILL.md for auth + security rules.
# Re-sync: re-download files/skills/{gws,persona,recipe}-*/SKILL.md and
# regenerate the list below.
%w(
  gws-admin-reports gws-calendar gws-calendar-agenda gws-calendar-insert gws-chat gws-chat-send
  gws-classroom gws-docs gws-docs-write gws-drive gws-drive-upload gws-events
  gws-events-renew gws-events-subscribe gws-forms gws-gmail gws-gmail-forward gws-gmail-read
  gws-gmail-reply gws-gmail-reply-all gws-gmail-send gws-gmail-triage gws-gmail-watch gws-keep
  gws-meet gws-modelarmor gws-modelarmor-create-template gws-modelarmor-sanitize-prompt gws-modelarmor-sanitize-response gws-people
  gws-script gws-script-push gws-shared gws-sheets gws-sheets-append gws-sheets-read
  gws-slides gws-tasks gws-workflow gws-workflow-email-to-task gws-workflow-file-announce gws-workflow-meeting-prep
  gws-workflow-standup-report gws-workflow-weekly-digest persona-content-creator persona-customer-support persona-event-coordinator persona-exec-assistant
  persona-hr-coordinator persona-it-admin persona-project-manager persona-researcher persona-sales-ops persona-team-lead
  recipe-backup-sheet-as-csv recipe-batch-invite-to-event recipe-block-focus-time recipe-bulk-download-folder recipe-collect-form-responses recipe-compare-sheet-tabs
  recipe-copy-sheet-for-new-month recipe-create-classroom-course recipe-create-doc-from-template recipe-create-events-from-sheet recipe-create-expense-tracker recipe-create-feedback-form
  recipe-create-gmail-filter recipe-create-meet-space recipe-create-presentation recipe-create-shared-drive recipe-create-task-list recipe-create-vacation-responder
  recipe-draft-email-from-doc recipe-email-drive-link recipe-find-free-time recipe-find-large-files recipe-forward-labeled-emails recipe-generate-report-from-sheet
  recipe-label-and-archive-emails recipe-log-deal-update recipe-organize-drive-folder recipe-plan-weekly-schedule recipe-post-mortem-setup recipe-reschedule-meeting
  recipe-review-meet-participants recipe-review-overdue-tasks recipe-save-email-attachments recipe-save-email-to-doc recipe-schedule-recurring-event recipe-send-team-announcement
  recipe-share-doc-and-notify recipe-share-event-materials recipe-share-folder-with-team recipe-sync-contacts-to-sheet recipe-watch-drive-changes
).each do |skill_name|
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

# Deploy single-file skills (markdown-only, no SKILL.md subdirectory)
remote_file "#{node[:setup][:home]}/.claude/skills/ingest-pdf.md" do
  source "files/skills/ingest-pdf.md"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  action :create
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

