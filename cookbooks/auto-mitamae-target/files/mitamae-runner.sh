#!/bin/bash
# auto-mitamae-target: forced-command target invoked by SSH from the
# orchestrator (monitoring LXC). The orchestrator's authorized_keys entry
# is `command="/usr/local/bin/mitamae-runner",restrict,from=192.168.1.76`,
# so $SSH_ORIGINAL_COMMAND carries `<role-path> <expected-sha>` only.
#
# Allowed input form:
#   <role-path> <expected-sha>
# where:
#   role-path matches ^[A-Za-z0-9._/-]+\.rb$
#   expected-sha matches ^[a-f0-9]{40}$
#
# Single output line on stdout for the orchestrator to parse:
#   status=<state> sha=<new-head> drift=<count> duration=<sec> old=<old-sha> ts=<utc-iso>
# (sha/drift/duration/old fields may be omitted on early-exit states.)
#
# Exit codes:
#   0  invalid_command (parse-failed) — but write status= line first
#      success
#      lock_held (orchestrator should record + retry next cron)
#   1  any error path (sha_mismatch, git_fetch_fail, mitamae_fail,
#      invalid_command). status= line still emitted.
#
# Design notes:
#   - flock per host, NOT per role: prevents two roles or a manual mitamae
#     from racing against the orchestrator on the same host
#   - `git checkout <expected-sha>` (not reset --hard) anchors to the SHA
#     the orchestrator observed; if origin/main has moved past expected-sha
#     between observe and apply, sha_mismatch fires before any state changes
set -euo pipefail
shopt -s inherit_errexit

# Preset AWS_PROFILE for the fleet non-TTY apply path. require_external_auth's
# profile auto-discovery is TTY-only, so without this env preset bare-gate
# cookbooks (ssh-keys etc.) would fall through to the `default` profile (which
# does not exist on a fresh LXC) and silently skip. The fleet's only configured
# profile is pve-bootstrap-ssm (seeded by bin/bootstrap-lxc-creds), so this is
# deterministic. Cookbooks that pin an explicit --profile are unaffected — the
# CLI flag wins over AWS_PROFILE.
export AWS_PROFILE=pve-bootstrap-ssm

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

cmd="${SSH_ORIGINAL_COMMAND:-}"
if [[ ! "$cmd" =~ ^([A-Za-z0-9._/-]+\.rb)\ ([a-f0-9]{40})$ ]]; then
    echo "status=invalid_command ts=$(ts)"
    exit 1
fi
role="${BASH_REMATCH[1]}"
expected_sha="${BASH_REMATCH[2]}"
setup_dir="/root/setup"

# flock per host. -n = non-blocking; if held, exit 0 with lock_held so the
# orchestrator records the skip without treating it as a hard failure.
exec 9>/var/lock/auto-mitamae.lock
if ! flock -n 9; then
    echo "status=lock_held ts=$(ts)"
    exit 0
fi

cd "$setup_dir"

old_sha=$(git rev-parse HEAD)

if ! git fetch --quiet origin main; then
    echo "status=git_fetch_fail old=$old_sha ts=$(ts)"
    exit 1
fi

actual_remote_sha=$(git rev-parse origin/main)
if [[ "$actual_remote_sha" != "$expected_sha" ]]; then
    echo "status=sha_mismatch expected=$expected_sha actual=$actual_remote_sha old=$old_sha ts=$(ts)"
    exit 1
fi

drift=$(git rev-list --count HEAD..origin/main)

# Discard any local drift in /root/setup before the checkout. A dirty
# working tree (stray edits to a tracked file, or an untracked cookbook
# file from a manual partial apply) makes `git checkout` abort. Under
# `set -e` that exits the runner BEFORE the status= line is printed, so the
# orchestrator sees no status, classifies the host ssh_unreachable, and the
# host silently never converges (observed on housekeeping/CT103, 2026-05:
# a local edit to roles/lxc-core/default.rb + untracked cookbooks/timezone/
# pinned it stale until a manual reset). The host must always track
# expected_sha; local modifications are never authoritative.
git reset --hard --quiet HEAD
git clean -fdq
git checkout --quiet "$expected_sha"

start=$(date +%s)
if ./bin/mitamae local "$role" >/tmp/auto-mitamae.log 2>&1; then
    status=success
    rc=0
else
    status=mitamae_fail
    rc=1
fi
duration=$(( $(date +%s) - start ))
new_sha=$(git rev-parse HEAD)

echo "status=$status sha=$new_sha drift=$drift duration=$duration old=$old_sha ts=$(ts)"
exit "$rc"
