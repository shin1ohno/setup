#!/usr/bin/env bash
#
# self-heal-resolve loop runner (headless, cron-invoked via `runuser -l <user>`).
# Managed by cookbooks/self-heal-loops. Do not edit by hand.
#
# Runs the self-heal-resolve skill via headless `claude -p` to drive open
# self-heal issues to a terminal state (resolved+closed, or needs-human). This
# mutates the fleet (git/gh/ssh/mitamae) under bypassPermissions — there is no
# human to answer permission prompts. Safety is enforced by the SKILL's
# boundaries (allowlist classes only, CI-green before merge, no destructive
# ops, 1 issue/run, 3-try escalation, functional verification) + this loop's
# kill-switch + the auto-mitamae canary gate, NOT by interactive approval.
#
# flock-guarded, timeout-capped, kill-switch-aware, opus-pinned for reasoning.
# Never fails the cron (log + .last are the liveness signal). claude is invoked
# by ABSOLUTE path (see self-heal-create-run.sh header for why).

set -uo pipefail

CLAUDE_BIN="${CLAUDE_BIN:-${HOME}/.local/bin/claude}"
LOG_DIR="${HOME}/.claude/logs"
LOG="${LOG_DIR}/self-heal-resolve.log"
LAST="${LOG_DIR}/self-heal-resolve.last"
LOCK="/tmp/self-heal-resolve.lock"
DISABLED_GLOBAL="${HOME}/.claude/self-heal-loops.DISABLED"
DISABLED_LOCAL="${HOME}/.claude/self-heal-resolve.DISABLED"
TIMEOUT="${SELF_HEAL_RESOLVE_TIMEOUT:-1800}"
MODEL="${SELF_HEAL_RESOLVE_MODEL:-opus}"

mkdir -p "${LOG_DIR}" 2>/dev/null || true
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(ts)] $*" >> "${LOG}"; }

if [ -f "${DISABLED_GLOBAL}" ] || [ -f "${DISABLED_LOCAL}" ]; then
  log "skip: DISABLED sentinel present"
  exit 0
fi

if [ ! -x "${CLAUDE_BIN}" ]; then
  log "ERROR: claude not executable at ${CLAUDE_BIN} (HOME=${HOME}) — skipping"
  exit 0
fi

read -r -d '' PROMPT <<'PEOF' || true
You are running headless on a schedule with NO human present. Goal: drive every
actionable open self-heal issue in shin1ohno/setup to a terminal state — either
resolved and closed, or labelled `self-heal-needs-human` with a diagnosis
comment. Use the self-heal-resolve skill and follow its safety boundaries
EXACTLY: only auto-apply remediation classes on the allowlist (A known-service
re-converge, B cookbook config fix); class C transient restart is limited; class
D (new design / destructive / auth / infra / unknown / ambiguous) escalates to
needs-human. Never merge before CI is green; never run destructive operations;
process one issue at a time; escalate (do not retry indefinitely) after 3
attempts on the same symptom; verify functional state, not artifacts.

Before starting, recover any partial state from a previous interrupted run:
an issue commented "🔧 着手" with no open linked PR (older than 30 min) should be
resumed; an issue with an open, CI-green linked PR should proceed to merge +
verify rather than be re-investigated; do not leave orphaned branches/PRs.

Keep working through actionable issues until none remain (every open self-heal
issue is either closed or labelled self-heal-needs-human), then print a summary
(resolved=N escalated=M) and stop. If you cannot make progress on an issue,
escalate it to needs-human with your findings rather than retrying or leaving
partial state.
PEOF

start=$(date +%s)
log "=== resolve cycle start (model=${MODEL}) ==="

exec 9>"${LOCK}"
if ! flock -n 9; then
  log "skip: another resolve run holds the lock"
  exit 0
fi

timeout "${TIMEOUT}" "${CLAUDE_BIN}" -p "${PROMPT}" \
  --permission-mode bypassPermissions --model "${MODEL}" >> "${LOG}" 2>&1
rc=$?

dur=$(( $(date +%s) - start ))
ts > "${LAST}"
log "=== resolve cycle end rc=${rc} dur=${dur}s ==="
exit 0
