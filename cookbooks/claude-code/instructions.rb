# frozen_string_literal: true

remote_file "#{node[:setup][:home]}/.claude/CLAUDE.md" do
  source "files/CLAUDE.md"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  action :create
end

# Shared instruction layer read by both agents: CLAUDE.md imports it with
# `@~/.agents/AGENTS.md`, and the codex-cli cookbook links ~/.codex/AGENTS.md to it.
directory "#{node[:setup][:home]}/.agents" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

remote_file "#{node[:setup][:home]}/.agents/AGENTS.md" do
  source "files/AGENTS.md"
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

%w(ask-user-question.md sub-agents.md git-commit.md mcp-config.md debugging.md editing.md planning.md adversarial-review.md).each do |file_name|
  remote_file "#{node[:setup][:home]}/.claude/rules/#{file_name}" do
    source "files/rules/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end

# Deploy docs (detail files referenced by CLAUDE.md and the rules/ files)
directory "#{node[:setup][:home]}/.claude/docs" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

%w(knowledge-persistence.md debugging-detail.md infrastructure-detail.md claude-cli-headless.md elasticsearch.md mcp-deployment.md neovim.md release-plz.md tailscale.md weave-protocol.md frontend-dev.md cookbook-prs.md mise-migration.md kibana-lens.md ios-build.md data-collection.md ruby-detail.md git-commit-detail.md shell-detail.md sub-agents-detail.md planning-detail.md aws-iam.md domain-writing.md rule-placement-detail.md pve-lxc-detail.md docker-compose-detail.md ffi-audit.md claude-code-plugins.md adversarial-review-detail.md negative-search-detail.md todo-management.md rust.md docker-compose.md fractal-nodes.md gpg-key-distribution.md codex-skills-probe.md claude-md-detail.md agents-md-detail.md knowledge-persistence-detail.md ask-user-question-detail.md).each do |file_name|
  remote_file "#{node[:setup][:home]}/.claude/docs/#{file_name}" do
    source "files/docs/#{file_name}"
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    action :create
  end
end


# Clean up rules/ files moved to docs/ (or inlined into CLAUDE.md) by #638/#639,
# the rules-diet round 2 (ffi-audit / claude-code-plugins / pve-lxc demoted to
# docs/), and round 3 (rust / docker-compose demoted — 2026-07 claude-md-audit:
# 1/240 sessions fired rust.md; frontmatter globs never gated loading), plus
# japanese-output.md (body now in the shared ~/.agents/AGENTS.md) and the
# claude-cli-headless.md / elasticsearch.md copies deployed earlier. mitamae
# only creates files from the deploy lists above — it never prunes entries
# removed from those lists, so every deployed host keeps loading the stale
# rules/ copies until they are deleted explicitly.
%w(
  architecture.md
  aws-iam.md
  claude-cli-headless.md
  claude-code-plugins.md
  cookbook-prs.md
  data-collection.md
  docker-compose.md
  elasticsearch.md
  ffi-audit.md
  frontend-dev.md
  infrastructure.md
  ios-build.md
  japanese-output.md
  kibana-lens.md
  mise-migration.md
  pve-lxc.md
  remote-trigger.md
  ruby.md
  rust.md
  shell.md
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
# docs/release-plz.md#crates-io-token-scopes; aws-iam-detail.md → merged into
# docs/aws-iam.md. Same non-pruning caveat as above.
%w(
  aws-iam-detail.md
  claude-code-plugins-detail.md
  remote-trigger.md
  rust-detail.md
).each do |file_name|
  file "#{node[:setup][:home]}/.claude/docs/#{file_name}" do
    action :delete
  end
end
