#!/usr/bin/env bash
#
# self-heal-create loop runner (headless, cron-invoked via `runuser -l <user>`).
# Managed by cookbooks/self-heal-loops. Do not edit by hand.
#
# Runs the PURE-SHELL self-heal-create.sh to sync the ES self-heal-state index
# to shin1ohno/setup GitHub issues. The sync is a deterministic set diff keyed by
# sha1(dedup_key), so no `claude -p` session is involved (previously this wrapper
# invoked the model every cycle; that was pure waste — the logic carries no model
# judgment). Read-only on ES; only touches self-heal-labelled issues; never
# closes self-heal-needs-human. flock-guarded, timeout-capped, kill-switch-aware,
# logs to ~/.claude/logs. Never fails the cron (the log + .last timestamp are the
# liveness signal). See docs/self-heal-github-issues-plan.md.
#
# runuser -l spawns a NON-interactive login shell that does not source .zshrc, so
# prepend the user tool dirs for aws/gh/jq/curl resolution.

set -uo pipefail

export PATH="${HOME}/.local/share/mise/shims:${HOME}/.local/bin:${PATH}"

CREATE_BIN="${SELF_HEAL_CREATE_BIN:-/usr/local/bin/self-heal-create.sh}"
LOG_DIR="${HOME}/.claude/logs"
LOG="${LOG_DIR}/self-heal-create.log"
LAST="${LOG_DIR}/self-heal-create.last"
LOCK="/tmp/self-heal-create.lock"
DISABLED_GLOBAL="${HOME}/.claude/self-heal-loops.DISABLED"
DISABLED_LOCAL="${HOME}/.claude/self-heal-create.DISABLED"
TIMEOUT="${SELF_HEAL_CREATE_TIMEOUT:-120}"

mkdir -p "${LOG_DIR}" 2>/dev/null || true
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(ts)] $*" >> "${LOG}"; }

if [ -f "${DISABLED_GLOBAL}" ] || [ -f "${DISABLED_LOCAL}" ]; then
  log "skip: DISABLED sentinel present"
  exit 0
fi

if [ ! -x "${CREATE_BIN}" ]; then
  log "ERROR: self-heal-create.sh not executable at ${CREATE_BIN} — skipping"
  exit 0
fi

start=$(date +%s)
log "=== create cycle start ==="

exec 9>"${LOCK}"
if ! flock -n 9; then
  log "skip: another create run holds the lock"
  exit 0
fi

timeout "${TIMEOUT}" "${CREATE_BIN}" >> "${LOG}" 2>&1
rc=$?

dur=$(( $(date +%s) - start ))
ts > "${LAST}"
log "=== create cycle end rc=${rc} dur=${dur}s ==="
exit 0
