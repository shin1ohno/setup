#!/usr/bin/env bash
#
# self-heal-create loop runner (headless, cron-invoked via `runuser -l <user>`).
# Managed by cookbooks/self-heal-loops. Do not edit by hand.
#
# Runs the self-heal-create skill via headless `claude -p` to sync the ES
# self-heal-state index to shin1ohno/setup GitHub issues. Read-only on ES;
# only touches self-heal-labelled issues. flock-guarded, timeout-capped,
# kill-switch-aware, logs to ~/.claude/logs. Never fails the cron (the log +
# .last timestamp are the liveness signal). See
# ~/self-heal-observability-loop-design.md + docs/self-heal-github-issues-plan.md.
#
# runuser -l sets HOME=<user home>; claude is invoked by ABSOLUTE path because
# ~/.local/bin is added to PATH by .zshrc (interactive only), not by the
# non-interactive login shell runuser spawns.

set -uo pipefail

CLAUDE_BIN="${CLAUDE_BIN:-${HOME}/.local/bin/claude}"
LOG_DIR="${HOME}/.claude/logs"
LOG="${LOG_DIR}/self-heal-create.log"
LAST="${LOG_DIR}/self-heal-create.last"
LOCK="/tmp/self-heal-create.lock"
DISABLED_GLOBAL="${HOME}/.claude/self-heal-loops.DISABLED"
DISABLED_LOCAL="${HOME}/.claude/self-heal-create.DISABLED"
TIMEOUT="${SELF_HEAL_CREATE_TIMEOUT:-300}"

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
You are running headless on a schedule (no interactive session). Use the
self-heal-create skill to sync shin1ohno/setup self-heal issues with the ES
self-heal-state index: open a GitHub issue for every self-heal-state doc with
status:open that has no open self-heal issue, and close any open self-heal
issue whose alert has cleared. This is READ-ONLY on Elasticsearch and must only
touch issues with the `self-heal` label (and never close `self-heal-needs-human`
issues). It is idempotent — make only the necessary diff. When the sync is
complete (or there is nothing to do), print a one-line summary
(created=N closed=M) and stop.
PEOF

start=$(date +%s)
log "=== create cycle start ==="

exec 9>"${LOCK}"
if ! flock -n 9; then
  log "skip: another create run holds the lock"
  exit 0
fi

timeout "${TIMEOUT}" "${CLAUDE_BIN}" -p "${PROMPT}" \
  --permission-mode bypassPermissions >> "${LOG}" 2>&1
rc=$?

dur=$(( $(date +%s) - start ))
ts > "${LAST}"
log "=== create cycle end rc=${rc} dur=${dur}s ==="
exit 0
