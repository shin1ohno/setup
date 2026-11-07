# frozen_string_literal: true

# Deploy skills. Shared skills keep their real files in ~/.agents/skills (the
# directory Codex reads) and are linked into ~/.claude/skills once their helper
# files are in place (agents_skill_link below). Claude-only skills depend on
# Claude Code's own state or tools and stay in ~/.claude/skills.
%w(.agents .agents/skills).each do |dir_name|
  directory "#{node[:setup][:home]}/#{dir_name}" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    action :create
  end
end

shared_skills = %w(writing interview verify research research-domains load-test check-services security-review feature-parity verify-mise-backend pr-ci-medic morning-triage self-heal-create self-heal-resolve network-log-audit web-crawl setup-release-plz session-search)

shared_skills.each do |skill_name|
  directory "#{node[:setup][:home]}/.agents/skills/#{skill_name}" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    action :create
  end

  remote_file "#{node[:setup][:home]}/.agents/skills/#{skill_name}/SKILL.md" do
    source "files/skills/#{skill_name}/SKILL.md"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end

include_recipe "chief-of-staff-skill.rb"

%w(retro bootstrap-docs-hub mcp-auth todo-reconcile todo-collect todo-approve linear-resolve).each do |skill_name|
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

# linear-resolve helpers. The SKILL.md describes the loop; these two files are
# the parts that must NOT be a model's judgement.
#
# linear_queue.py decides which issue the loop may work and whether an operator
# comment counts as approval. It is pure and testable precisely so that decision
# is reviewable without reading a transcript — and because the bot writes with
# the operator's own personal API key, author id cannot separate the loop from
# the human, so the marker match it implements is the whole of the identity
# check. test_linear_queue.py is test-only and intentionally excluded, same as
# the todo-collect helpers above.
remote_file "#{node[:setup][:home]}/.claude/skills/linear-resolve/linear_queue.py" do
  source "files/skills/linear-resolve/linear_queue.py"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

# probe.sh is the loop's ONLY route to observing production, and it exists
# because a tool deny-list is decorative against a `claude -p` worker that has
# Bash: anything reachable with a credential in the environment is reachable
# with curl or ssh. The credential lives in this script instead, the worker gets
# none, and the set of subcommands IS the set of things the loop may observe.
# It fails closed — the default AWS profile name does not exist until the
# dedicated read-only principal is provisioned, so an unconfigured deployment
# errors rather than quietly borrowing an admin profile.
remote_file "#{node[:setup][:home]}/.claude/skills/linear-resolve/probe.sh" do
  source "files/skills/linear-resolve/probe.sh"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

# Deploy network-log-audit references. The SKILL.md is deliberately thin (entry
# point + the comparison discipline); the bulk — ES catalog, retention limits,
# read-only device probes, known traps — lives here so it is loaded only when a
# network investigation actually needs it.
directory "#{node[:setup][:home]}/.agents/skills/network-log-audit/references" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w(es-catalog.md retention.md probes.md pitfalls.md).each do |file_name|
  remote_file "#{node[:setup][:home]}/.agents/skills/network-log-audit/references/#{file_name}" do
    source "files/skills/network-log-audit/references/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end

# Deploy writing skill templates
directory "#{node[:setup][:home]}/.agents/skills/writing/templates" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w(dvq.md rfc.md).each do |file_name|
  remote_file "#{node[:setup][:home]}/.agents/skills/writing/templates/#{file_name}" do
    source "files/skills/writing/templates/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end

# Deploy writing skill personas
directory "#{node[:setup][:home]}/.agents/skills/writing/personas" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w(document-writer.md marginal-utility-editor.md).each do |file_name|
  remote_file "#{node[:setup][:home]}/.agents/skills/writing/personas/#{file_name}" do
    source "files/skills/writing/personas/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end

# Deploy writing skill references (Japanese AI-slop removal)
# Only the 3 reference files ship; references/fixtures/ is test-only and intentionally excluded.
directory "#{node[:setup][:home]}/.agents/skills/writing/references" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w(phrases.md structures.md examples.md).each do |file_name|
  remote_file "#{node[:setup][:home]}/.agents/skills/writing/references/#{file_name}" do
    source "files/skills/writing/references/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end

# Deploy writing skill scripts (SKILL.md Step 3b runs both). content_diff.py
# flags numbers a rewrite added or changed; slop_scan.py is the advisory scan for
# the three pathologies and shells out to vendor/yomiyasu_lint.py, which is an
# unmodified upstream copy (MIT; see vendor/README.md) shipped with its LICENSE.
# test_content_diff.py and test_slop_scan.py are repo-only and intentionally
# excluded, same as writing/references/fixtures/ above.
%w(scripts scripts/vendor).each do |dir_name|
  directory "#{node[:setup][:home]}/.agents/skills/writing/#{dir_name}" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    action :create
  end
end

%w(content_diff.py slop_scan.py).each do |file_name|
  remote_file "#{node[:setup][:home]}/.agents/skills/writing/scripts/#{file_name}" do
    source "files/skills/writing/scripts/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    action :create
  end
end

%w(yomiyasu_lint.py).each do |file_name|
  remote_file "#{node[:setup][:home]}/.agents/skills/writing/scripts/vendor/#{file_name}" do
    source "files/skills/writing/scripts/vendor/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    action :create
  end
end

%w(LICENSE-yomiyasu README.md).each do |file_name|
  remote_file "#{node[:setup][:home]}/.agents/skills/writing/scripts/vendor/#{file_name}" do
    source "files/skills/writing/scripts/vendor/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end

# Claude Code does not read ~/.agents/skills, so each shared skill gets a symlink
# in ~/.claude/skills. Runs after every helper file above is in place.
shared_skills.each do |skill_name|
  agents_skill_link skill_name
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

# Deploy the todo-collect helper script. The skills loop above ships SKILL.md
# and nothing else, but /todo-collect Step 6 shells out to this file
# (`ruby remind_sync.rb --config ... --apply`) — so SKILL.md alone leaves the
# Apple Reminders mirror sync unrunnable on every host. Its sibling
# test_remind_sync.rb is test-only and intentionally excluded, same as
# writing/references/fixtures/ above.
remote_file "#{node[:setup][:home]}/.claude/skills/todo-collect/remind_sync.rb" do
  source "files/skills/todo-collect/remind_sync.rb"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

# Deploy the todo-collect queue helper (docs/todo-management.md "Queue").
# /todo-collect Step 0a/4/5, /todo-reconcile and /todo-approve all shell out to
# it, and the headless runner on the work box regenerates summary.txt with it on
# every path — so SKILL.md alone leaves the approval queue unbuildable. It is
# python3 (stdlib only), not Ruby like remind_sync.rb: the systemd user PATH the
# runner inherits resolves /usr/bin/python3 and no rbenv shim. test_todo_queue.py
# is test-only and intentionally excluded, same as test_remind_sync.rb above.
remote_file "#{node[:setup][:home]}/.claude/skills/todo-collect/todo_queue.py" do
  source "files/skills/todo-collect/todo_queue.py"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

# mw_client.py — the one place that speaks MCP streamable-HTTP to a memory store and
# composes the todo / todo-disposition record grammar. Until now only a model session
# could write those records, because only a model held an MCP client; every
# deterministic surface (an approval UI, a sync script, a cron job) needs the same
# session dance, the same grammar and the same same-decision guard, and
# re-implementing the grammar per surface is how a record ends up unreadable by
# todo_queue.py's parser. Importable as a module and usable as a CLI; python3 stdlib
# only, for the same PATH reason as todo_queue.py above.
# test_mw_client.py is test-only and intentionally excluded, same as above.
remote_file "#{node[:setup][:home]}/.claude/skills/todo-collect/mw_client.py" do
  source "files/skills/todo-collect/mw_client.py"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
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

# Retired skill deployment.
file "#{node[:setup][:home]}/.claude/skills/audit-claudemd/SKILL.md" do
  action :delete
end

directory "#{node[:setup][:home]}/.claude/skills/audit-claudemd" do
  action :delete
end
