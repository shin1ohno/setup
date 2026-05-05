#!/usr/bin/env bash
# auto-mitamae runner: pull origin/main, apply role if HEAD changed.
#
# Phase 1 scope: log to journald via systemd's StandardOutput/Error capture.
# Dashboard POST + retry/skip statuses come in Phase 2.
#
# Required env (set by the systemd unit):
#   SETUP_DIR  — git checkout of shin1ohno/setup (e.g. /root/setup)
#   ROLE_FILE  — relative path of the entry recipe (e.g. pve/lxc-weave.rb)

set -euo pipefail
shopt -s inherit_errexit

: "${SETUP_DIR:?SETUP_DIR must be set}"
: "${ROLE_FILE:?ROLE_FILE must be set}"

# Lock + log placement: root path uses /run + /var/log; user path falls back
# to XDG_RUNTIME_DIR / ~/.cache so the same script can be reused for the
# user-mode tracks (pro-dev / Mac) in later phases.
if [[ $EUID -eq 0 ]]; then
    lock_dir="/run"
    log_dir="/var/log"
else
    lock_dir="${XDG_RUNTIME_DIR:-$HOME/.cache}"
    log_dir="$HOME/.cache"
    mkdir -p "$lock_dir" "$log_dir"
fi
lock_file="${lock_dir}/auto-mitamae.lock"
log_file="${log_dir}/auto-mitamae.log"

# Exclusive non-blocking lock against concurrent timer + manual mitamae.
exec 9>"$lock_file"
if ! flock -n 9; then
    echo "auto-mitamae: another run holds ${lock_file}, skipping"
    exit 0
fi

cd "$SETUP_DIR"

old_sha=$(git rev-parse HEAD)
if ! git fetch --quiet origin main; then
    echo "auto-mitamae: git fetch failed, will retry on next timer fire" >&2
    exit 0
fi
git reset --hard --quiet origin/main
new_sha=$(git rev-parse HEAD)

if [[ "$old_sha" == "$new_sha" ]]; then
    echo "auto-mitamae: HEAD unchanged at ${new_sha:0:7}, skipping apply"
    exit 0
fi

echo "auto-mitamae: ${old_sha:0:7} -> ${new_sha:0:7}, applying ${ROLE_FILE}"

start=$(date +%s)
if ./bin/mitamae local "$ROLE_FILE" 2>&1 | tee "$log_file"; then
    duration=$(( $(date +%s) - start ))
    echo "auto-mitamae: success at ${new_sha:0:7} in ${duration}s"
else
    rc=$?
    duration=$(( $(date +%s) - start ))
    echo "auto-mitamae: FAILURE rc=${rc} at ${new_sha:0:7} after ${duration}s" >&2
    exit "$rc"
fi
