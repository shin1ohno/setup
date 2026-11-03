# frozen_string_literal: true

herdr_path = "#{node[:setup][:home]}/.local/bin/herdr"

# Agent skill for Claude Code + Codex CLI. herdr ships its own instructions
# inside the binary (`herdr --skill` — 195 lines at 0.8.0, covering the CLI
# surface, the pane/agent lifecycle states, and the "never stop the server you
# did not start" safety rules), so generate from the pinned binary instead of
# vendoring a copy that silently rots at the next bump. files/skill-local.md
# appends what upstream cannot know: config.toml is a cookbook render target,
# `herdr update` fights the version pin, and `hr` is the session entry point.
# Caller verification also supports shared app-server tools without inherited env.
skill_local = File.join(File.dirname(__FILE__), "files", "skill-local.md")
# One composition, used by both the install command and its guard. Emitting on
# stdout lets the guard be a plain `| cmp -s - <dst>` (no process substitution,
# so it works under mitamae's /bin/sh), and makes a herdr bump OR an edit to
# skill-local.md regenerate both copies on the next apply.
skill_composer = File.join(File.dirname(__FILE__), "files", "compose-skill.py")
skill_body = %(python3 "#{skill_composer}" "#{herdr_path}" "#{skill_local}")

# Both agents read <name>/SKILL.md and share the same YAML frontmatter shape, so
# one composed file serves both. The real file lives in ~/.agents/skills/herdr,
# the directory Codex reads; Claude Code does not read it, so
# ~/.claude/skills/herdr is a symlink to it. Every entry recipe that includes
# roles/core (this cookbook) also includes roles/llm (claude-code, codex-cli) —
# darwin.rb, linux.rb, cookbooks/lxc-dev-workstation — so neither agent is
# missing on a host that has the skill.
skill_dir = "#{node[:setup][:home]}/.agents/skills/herdr"

["#{node[:setup][:home]}/.agents", "#{node[:setup][:home]}/.agents/skills", skill_dir].each do |dir|
  directory dir do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
  end
end

remote_file "#{skill_dir}/caller-context.py" do
  source "files/caller-context.py"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
end

execute "install herdr agent skill" do
  user node[:setup][:user]
  # bash -c for `set -o pipefail` (dash rejects it), same as the install
  # above. Compose into a temp file and `install` it so a mid-pipeline
  # failure cannot leave a half-written SKILL.md in place.
  command <<~SH.strip
    bash -c '
      set -euo pipefail
      tmp="$(mktemp)"
      trap "rm -f $tmp" EXIT
      #{skill_body} > "$tmp"
      install -m 0644 "$tmp" "#{skill_dir}/SKILL.md"
    '
  SH
  not_if "bash -c '#{skill_body}' | cmp -s - #{skill_dir}/SKILL.md"
end

agents_skill_link "herdr"

# Codex used to get its own copy under $CODEX_HOME/skills. It scans both that
# directory and ~/.agents/skills and dedups by canonical path, so leaving the
# old copy would list herdr twice.
directory "#{node[:setup][:home]}/.codex/skills/herdr" do
  action :delete
end

