#!/bin/bash
# SessionStart hook (Claude Code cloud only): converge herdr + the Chief of
# Staff skill via claude-code-cloud.rb. Idempotent; the fast path costs a few sha256sums.
set -euo pipefail

# Cloud sessions only; never touch a developer's own machine.
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
# Workers launched by Chief of Staff run inside herdr panes (HERDR_ENV=1).
# They must not trigger an install.
[ -z "${HERDR_ENV:-}" ] || exit 0

root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
export USER="${USER:-$(id -un)}"
state_dir="${HOME}/.cache/setup-cloud"
hashes="${state_dir}/session-start.sha256"
mkdir -p "$state_dir"

# Inputs that decide what gets installed.
inputs=(
  .claude/hooks/session-start.sh
  claude-code-cloud.rb
  cookbooks/herdr/default.rb
  cookbooks/herdr/agent-skill.rb
  cookbooks/herdr/files/compose-skill.py
  cookbooks/herdr/files/caller-context.py
  cookbooks/herdr/files/skill-local.md
  cookbooks/claude-code/chief-of-staff-skill.rb
  cookbooks/claude-code/files/skills/chief-of-staff/SKILL.md
  cookbooks/claude-code/files/skills/chief-of-staff/agents/openai.yaml
  cookbooks/claude-code/files/skills/chief-of-staff/references/dispatch.md
  cookbooks/claude-code/files/skills/chief-of-staff/scripts/tasks.py
)

converged() {
  [ -x "${HOME}/.local/bin/herdr" ] \
    && [ -f "${HOME}/.agents/skills/herdr/SKILL.md" ] \
    && [ -f "${HOME}/.agents/skills/chief-of-staff/SKILL.md" ] \
    && (cd "$root" && sha256sum --check --status "$hashes") 2>/dev/null
}

converged && exit 0

# One installer at a time when several sessions start together.
exec 9>"${state_dir}/lock"
flock 9
converged && exit 0

rm -f "$hashes"
cd "$root"
[ -x bin/mitamae ] || ./bin/setup
./bin/mitamae local claude-code-cloud.rb
sha256sum "${inputs[@]}" > "$hashes"
