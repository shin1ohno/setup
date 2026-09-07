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
#   status=<state> sha=<new-head> drift=<count> duration=<sec> old=<old-sha> verified_sha=<sha> ts=<utc-iso>
# (sha/drift/duration/old/verified_sha fields may be omitted on early-exit states.)
#
# verified_sha (ADR 0009) is emitted on success and up_to_date ONLY, and is
# the SHA this host has a recorded successful apply for. On up_to_date it is
# always == sha == expected_sha: the runner never emits up_to_date unless the
# persisted state proves expected_sha succeeded here and the most recent
# attempt did not fail. The orchestrator's canary gate requires it.
#
# Exit codes:
#   0  invalid_command (parse-failed) — but write status= line first
#      success
#      up_to_date (already at target SHA, converge throttled this cycle)
#      lock_held (orchestrator should record + retry next cron)
#   1  any error path (sha_mismatch, git_fetch_fail, mitamae_fail,
#      invalid_command, state_write_fail). status= line still emitted.
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
#   - Per-SHA apply state (ADR 0009): the throttle above used to key off a
#     bare success TIMESTAMP. Because the working tree is re-anchored to
#     expected_sha BEFORE the throttle decision, a NEW sha whose apply FAILED
#     left HEAD == expected_sha, so the next cycle saw drift==0, found the
#     PREVIOUS sha's fresh timestamp, and returned up_to_date — the failed sha
#     was never retried and the orchestrator read up_to_date as canary
#     success. The state file now records WHICH sha succeeded and how the
#     most recent attempt ended; up_to_date requires a recorded success for
#     expected_sha itself AND a non-failed last attempt.
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
# Path overrides exist ONLY for the hermetic regression harness
# (cookbooks/auto-mitamae-target/test/run-state-scenarios.sh). They are
# honoured only when this process is NOT an ssh session: sshd sets
# SSH_CONNECTION for every session including forced commands, so the
# production entry always runs with the defaults regardless of the target
# sshd's AcceptEnv / PermitUserEnvironment (which `restrict` does not
# constrain — ADR 0009 review D8). The RECONCILE_* knobs below follow the
# same rule.
if [[ -n "${SSH_CONNECTION:-}" ]]; then
    unset AUTO_MITAMAE_SETUP_DIR AUTO_MITAMAE_APPLY_LOG AUTO_MITAMAE_LOCK_FILE \
          AUTO_MITAMAE_STATE_DIR AUTO_MITAMAE_RECONCILE_INTERVAL_SEC AUTO_MITAMAE_RECONCILE_JITTER_SEC
fi
setup_dir="${AUTO_MITAMAE_SETUP_DIR:-/root/setup}"
apply_log="${AUTO_MITAMAE_APPLY_LOG:-/tmp/auto-mitamae.log}"
lock_file="${AUTO_MITAMAE_LOCK_FILE:-/var/lock/auto-mitamae.lock}"

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
# State lives OUTSIDE setup_dir: the converge path runs `git clean -fdq`
# inside /root/setup, which would delete an untracked file kept in-tree.
# apply-state is the ADR 0009 per-SHA record; last-converge.epoch is the
# pre-0009 timestamp-only stamp, no longer read (it cannot say WHICH sha
# succeeded) and removed on the first post-0009 success.
STATE_DIR="${AUTO_MITAMAE_STATE_DIR:-/var/lib/auto-mitamae}"
STATE_FILE="${STATE_DIR}/apply-state"
LEGACY_STAMP_FILE="${STATE_DIR}/last-converge.epoch"

# Atomic state write: tmp + mv (same filesystem) so a reader (the next
# cycle, or an operator) never sees a partial file. Fields, in order:
#   last_success_sha / last_success_role / last_success_epoch — the proof
#     that (sha, role) converged here. role is part of the key: a hosts.json
#     role change on the same sha must not inherit the old role's success.
#   last_attempt_sha / last_attempt_status / last_attempt_epoch — diagnostics
#     + the retry guard. status is in_progress (written BEFORE mitamae runs,
#     so an interrupted apply can never leave the old proof valid), success,
#     or mitamae_fail.
# Returns non-zero (and removes its temp file) on ANY failure; every step is
# checked explicitly because callers invoke this inside `if !`, where errexit
# is suspended (ADR 0009 review D3). A caller that cannot record state must
# answer status=state_write_fail rather than die before the status line.
write_state() {
    local s_sha="$1" s_role="$2" s_epoch="$3" a_sha="$4" a_status="$5" a_epoch="$6" tmp
    tmp=$(mktemp "${STATE_FILE}.tmp.XXXXXX") || return 1
    if ! printf 'last_success_sha=%s\nlast_success_role=%s\nlast_success_epoch=%s\nlast_attempt_sha=%s\nlast_attempt_status=%s\nlast_attempt_epoch=%s\n' \
            "$s_sha" "$s_role" "$s_epoch" "$a_sha" "$a_status" "$a_epoch" > "$tmp"; then
        rm -f "$tmp"; return 1
    fi
    if ! mv -f "$tmp" "$STATE_FILE"; then rm -f "$tmp"; return 1; fi
    return 0
}

# flock per host. -n = non-blocking; if held, exit 0 with lock_held so the
# orchestrator records the skip without treating it as a hard failure.
exec 9>"$lock_file"
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
mkdir -p "$STATE_DIR"
now_epoch=$(date +%s)

# Read the per-SHA apply state (ADR 0009). Every field is sanitized
# independently: a missing/corrupt value means "no recorded success" and the
# host converges — never the other way round. A non-numeric or partial body
# must not abort under `set -u` BEFORE the status= line (that would surface as
# silent ssh_unreachable every cycle), hence the defaults on every read.
last_success_sha=""
last_success_role=""
last_success_epoch=0
last_attempt_sha=""
last_attempt_status=""
state_invalid=0
seen_keys=" "
if [[ -f "$STATE_FILE" ]]; then
    # `|| [[ -n "$k" ]]` processes a final line without a trailing newline;
    # a duplicated key invalidates the whole record (ADR 0009 review D2).
    while IFS='=' read -r k v || [[ -n "$k" ]]; do
        case "$seen_keys" in *" $k "*) state_invalid=1 ;; esac
        seen_keys="$seen_keys$k "
        case "$k" in
            last_success_sha)    last_success_sha="$v" ;;
            last_success_role)   last_success_role="$v" ;;
            last_success_epoch)  last_success_epoch="$v" ;;
            last_attempt_sha)    last_attempt_sha="$v" ;;
            last_attempt_status) last_attempt_status="$v" ;;
            last_attempt_epoch)  : ;;
            "") : ;;
            *) state_invalid=1 ;;
        esac
    done < "$STATE_FILE"
fi
[[ "$last_success_sha" =~ ^[a-f0-9]{40}$ ]] || last_success_sha=""
[[ "$last_success_role" =~ ^[A-Za-z0-9._/-]+\.rb$ ]] || last_success_role=""
[[ "$last_attempt_sha" =~ ^[a-f0-9]{40}$ ]] || last_attempt_sha=""
# Decimal, no leading zero (bash would read 09 as octal and abort the
# arithmetic below BEFORE the status line), at most 12 digits (year 33658).
[[ "$last_success_epoch" =~ ^(0|[1-9][0-9]{0,11})$ ]] || last_success_epoch=0
if [[ "$state_invalid" -eq 1 ]]; then last_success_sha=""; last_attempt_status=""; fi
# A future-dated success (clock jumped ahead, e.g. NTP not yet synced on a
# fresh LXC, then corrected backward) would otherwise throttle the host until
# that time — treat it as unknown and converge now.
if [[ "$last_success_epoch" -gt "$now_epoch" ]]; then last_success_epoch=0; fi

# The 4 conditions that together permit skipping the converge (ADR 0009):
#   1. drift == 0                             — no new origin/main commit
#   2. last_success_{sha,role} == expected/role — THIS sha+role succeeded here
#   3. last_attempt_status == success         — the most recent attempt neither
#                                               failed nor was interrupted
#   4. now < last_success + INTERVAL + jitter — inside the reconcile window
# (2) is what the timestamp-only stamp lacked: after "A succeeded, then B
# failed", HEAD is already B (re-anchored above) so drift==0, and A's fresh
# timestamp alone would have suppressed B's retry. (3) covers a failed or
# interrupted attempt at the same sha: the success record still names it,
# but the attempt must be retried next cycle, not throttled.
verified=0
if [[ -n "$last_success_sha" && "$last_success_sha" == "$expected_sha" \
      && "$last_success_role" == "$role" \
      && "$last_attempt_status" == "success" ]]; then
    verified=1
fi
# Seed the jitter from the role path (unique per fleet entry) so the offset
# is deterministic per host but spread across the fleet.
jitter_span=$((RECONCILE_JITTER_SEC + 1))
host_jitter=$(($(printf '%s' "$role" | cksum | cut -d' ' -f1) % jitter_span))
reconcile_due=$((last_success_epoch + RECONCILE_INTERVAL_SEC + host_jitter))
if [[ "$drift" -eq 0 && "$verified" -eq 1 && "$now_epoch" -lt "$reconcile_due" ]]; then
    new_sha=$(git rev-parse HEAD)
    echo "status=up_to_date sha=$new_sha drift=0 duration=0 old=$old_sha verified_sha=$last_success_sha ts=$(ts)"
    exit 0
fi

start=$(date +%s)
new_sha=$(git rev-parse HEAD)
# Invalidate BEFORE the first side effect: if this process is killed mid-apply
# (host reboot, OOM, an operator ^C on a manual run) no final record is
# written, and without this line the previous success would still satisfy
# condition (3) next cycle. in_progress fails (3), so an interrupted apply is
# always retried. Still inside the flock, so no other runner can observe a
# half-applied host as verified.
if ! write_state "$last_success_sha" "$last_success_role" "$last_success_epoch" "$new_sha" in_progress "$start"; then
    echo "status=state_write_fail sha=$new_sha drift=$drift duration=0 old=$old_sha ts=$(ts)"
    exit 1
fi
if ./bin/mitamae local "$role" >"$apply_log" 2>&1; then
    status=success
    end_epoch=$(date +%s)
    # Success: every field advances to this sha+role, so the next drift==0
    # cycle can throttle until the reconcile window. The legacy timestamp
    # stamp is no longer read; drop it once the per-SHA record exists.
    if write_state "$new_sha" "$role" "$end_epoch" "$new_sha" success "$end_epoch"; then
        rm -f "$LEGACY_STAMP_FILE"
        verified_field=" verified_sha=$new_sha"
        rc=0
    else
        # The apply succeeded but the proof could not be recorded: report it
        # as such, without verified_sha, so the next cycle converges again
        # rather than trusting an unrecorded success.
        status=state_write_fail
        verified_field=""
        rc=1
    fi
else
    status=mitamae_fail
    end_epoch=$(date +%s)
    # Failure: record ONLY the attempt. last_success_* keeps naming the
    # sha+role that last succeeded here (it may differ from new_sha), and the
    # failed attempt guarantees the next cycle converges again instead of
    # throttling — the retry-every-cycle contract ADR 0006 intended.
    write_state "$last_success_sha" "$last_success_role" "$last_success_epoch" "$new_sha" mitamae_fail "$end_epoch" || status=state_write_fail
    verified_field=""
    rc=1
fi
duration=$(( end_epoch - start ))

echo "status=$status sha=$new_sha drift=$drift duration=$duration old=$old_sha${verified_field} ts=$(ts)"
exit "$rc"
