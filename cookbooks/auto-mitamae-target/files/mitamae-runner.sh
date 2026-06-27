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
#      up_to_date (already at target SHA, converge throttled this cycle)
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
#   - Two-tier converge cadence (the fleet runs ALL its LXCs on ONE physical
#     Proxmox host, so an unconditional full mitamae converge on every host
#     every 5-min orchestrator cycle pegged the shared host continuously —
#     this is the "self-update overloads the PVE host" fix):
#       * git drift > 0 (a new origin/main commit) → converge NOW. New code
#         rolls out promptly and the canary gate still validates it.
#       * git drift == 0 (host already at the target SHA) → converge only
#         once per RECONCILE_INTERVAL_SEC (+ per-host jitter), otherwise emit
#         status=up_to_date and exit without running mitamae. The reconcile
#         still catches on-host config drift, just on a calm cadence instead
#         of every cycle. Jitter (seeded from the role path) de-syncs the
#         fleet so a commit-triggered synchronized apply does not resync all
#         hosts' next reconcile into a single cycle (thundering herd).
#     The orchestrator still SSHes every host every cycle and still gets a
#     status= line back, so apply-timestamp freshness (AutoMitamaeApplyStale)
#     is unaffected; only the expensive converge is throttled.
#     Operators forcing a full converge use bin/apply-pve-lxcs, which runs
#     mitamae directly and bypasses this runner entirely.
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

# Two-tier converge cadence (see header). When the host is already at the
# target SHA, re-converge at most once per RECONCILE_INTERVAL_SEC plus a
# per-host jitter window, instead of every orchestrator cycle.
#
# To change FLEET behaviour, edit these defaults — the change rolls out via
# the same auto-mitamae mechanism. The AUTO_MITAMAE_* env overrides do NOT
# reach the orchestrator's forced-command invocation (sshd drops client env
# and the authorized_keys entry is `restrict`); they exist only for manual /
# local-test runs of this script.
RECONCILE_INTERVAL_SEC="${AUTO_MITAMAE_RECONCILE_INTERVAL_SEC:-3600}"
RECONCILE_JITTER_SEC="${AUTO_MITAMAE_RECONCILE_JITTER_SEC:-3600}"
# Stamp lives OUTSIDE setup_dir: the converge path runs `git clean -fdq`
# inside /root/setup, which would delete an untracked stamp kept in-tree.
STAMP_DIR="/var/lib/auto-mitamae"
STAMP_FILE="${STAMP_DIR}/last-converge.epoch"

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

# Re-anchor the working tree to expected_sha EVERY cycle, BEFORE the converge
# throttle below. These are cheap, sub-second local git ops — NOT the
# PVE-host load source (only `./bin/mitamae local` is), so they are never
# throttled. Running them unconditionally preserves two invariants the
# throttle would otherwise weaken:
#   1. CT103 invariant — a dirty working tree (stray edits to a tracked file,
#      or an untracked cookbook file from a manual partial apply) makes a
#      later `git checkout` abort; under `set -e` that exits BEFORE the
#      status= line, the orchestrator classifies the host ssh_unreachable,
#      and the host silently never converges (observed on housekeeping/CT103,
#      2026-05: a local edit to roles/lxc-core/default.rb + untracked
#      cookbooks/timezone/ pinned it stale until a manual reset). The host
#      must always track expected_sha; local modifications are never
#      authoritative — so reset/clean every cycle, not just on reconcile.
#   2. drift==0 is NOT the same as HEAD==expected_sha: `git rev-list --count
#      HEAD..origin/main` is 0 whenever origin/main is an ANCESTOR of HEAD,
#      including when HEAD is AHEAD of origin/main (a stray local commit in
#      /root/setup). The unconditional `git checkout expected_sha` forces
#      HEAD to the orchestrator-observed SHA in that case too, so the
#      up_to_date status below always reports the real, correct HEAD.
git reset --hard --quiet HEAD
git clean -fdq
git checkout --quiet "$expected_sha"

# Two-tier converge cadence — the actual load fix. After the re-anchor above,
# HEAD == expected_sha for certain. drift (computed pre-checkout) tells us
# whether this cycle carried NEW code:
#   - drift > 0  → a new origin/main commit just landed: converge NOW so code
#     rollout latency and the canary gate are unaffected.
#   - drift == 0 → host was already on the target code: the only reason to run
#     mitamae is on-host config drift, which does not need correcting every
#     5-min cycle. Throttle the converge to RECONCILE_INTERVAL_SEC + a
#     per-host jitter so the shared Proxmox host is not pegged by all LXCs
#     converging continuously; otherwise emit up_to_date and exit.
#
# Arithmetic uses the var=$((...)) assignment form throughout: a standalone
# `(( expr ))` evaluating to 0 returns exit status 1, which under `set -e`
# would abort the runner before the status= line is printed. The clock-skew
# guard is written as `if/then/fi`, NOT `cond && action`, for the same reason
# (`[[ false ]] && x` returns 1 → abort).
mkdir -p "$STAMP_DIR"
now_epoch=$(date +%s)
last_converge=$(cat "$STAMP_FILE" 2>/dev/null || echo 0)
# Sanitize the stamp: a non-numeric body (corrupt/partial write, stray editor
# save) would make the arithmetic below abort under `set -u` BEFORE the
# status= line → silent ssh_unreachable every cycle. Empty is fine (treated
# as 0). A future-dated stamp (clock jumped ahead, e.g. NTP not yet synced on
# a fresh LXC, then corrected backward) would otherwise throttle the host
# forever — treat it as unknown and converge now.
[[ "$last_converge" =~ ^[0-9]+$ ]] || last_converge=0
if [[ "$last_converge" -gt "$now_epoch" ]]; then last_converge=0; fi
# Seed the jitter from the role path (unique per fleet entry) so the offset
# is deterministic per host but spread across the fleet.
jitter_span=$((RECONCILE_JITTER_SEC + 1))
host_jitter=$(($(printf '%s' "$role" | cksum | cut -d' ' -f1) % jitter_span))
reconcile_due=$((last_converge + RECONCILE_INTERVAL_SEC + host_jitter))
if [[ "$drift" -eq 0 && "$now_epoch" -lt "$reconcile_due" ]]; then
    new_sha=$(git rev-parse HEAD)
    echo "status=up_to_date sha=$new_sha drift=0 duration=0 old=$old_sha ts=$(ts)"
    exit 0
fi

start=$(date +%s)
if ./bin/mitamae local "$role" >/tmp/auto-mitamae.log 2>&1; then
    status=success
    # Record the converge time so drift==0 cycles can throttle until the
    # next reconcile window. Stamp ONLY on success: a failed converge must
    # keep retrying every cycle (and alert) rather than back off.
    date +%s > "$STAMP_FILE"
    rc=0
else
    status=mitamae_fail
    rc=1
fi
duration=$(( $(date +%s) - start ))
new_sha=$(git rev-parse HEAD)

echo "status=$status sha=$new_sha drift=$drift duration=$duration old=$old_sha ts=$(ts)"
exit "$rc"
