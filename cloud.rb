# frozen_string_literal: true

# Entry recipe for Claude Code cloud sessions (CLAUDE_CODE_REMOTE=true), applied
# by .claude/hooks/session-start.sh. Deliberately minimal: herdr (binary +
# agent skill) and the Chief of Staff skill. Full roles are NOT included:
# roles/core pulls shell/font tooling, roles/llm pulls mcp -> nodejs -> rbenv
# and SSM credentials, none of which a cloud container has or needs.

include_recipe "cookbooks/functions/default"

include_cookbook "herdr"

# Standalone: needs only remote_file + agents_skill_link, no claude-code state.
include_recipe "cookbooks/claude-code/chief-of-staff-skill.rb"
