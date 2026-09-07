#!/bin/bash
# orchestrator.sh — central auto-mitamae fleet orchestrator (Phase 2b).
#
# 1. Read drift-checker's last-observed main HEAD SHA from a sibling
#    textfile metric. Skip the cycle if drift-checker hasn't run yet OR its
#    last poll was an api_failure (no point pushing a stale SHA).
# 2. Phase A (canary): iterate hosts.json entries with `canary: true`
#    first. If any canary host fails apply, abort the cycle without
#    touching non-canary hosts — the cookbook bug is contained to the
#    canary's blast radius. Recovery is automatic: when the next commit
#    fixes the bug, drift-checker observes the new SHA, orchestrator
#    re-runs canary on the new SHA, succeeds, then rolls out to fleet.
# 3. Phase B (fleet): iterate remaining non-canary hosts.
# 4. Capture per-host status from each runner's one-line stdout into a
#    tmp textfile, atomic-mv into place.
#
# Status enum (matches mitamae-runner.sh):
#   success | up_to_date | mitamae_fail | sha_mismatch | git_fetch_fail
#   | lock_held | invalid_command | ssh_unreachable
#
# ssh_unreachable is orchestrator-side: ssh exited non-zero AND the runner
# never produced a `status=` line. Anything else is the runner's verdict.
#
# up_to_date is a healthy steady-state verdict: the host is already on the
# target SHA and the runner throttled its config-drift converge to a calmer
# cadence (mitamae-runner.sh two-tier cadence) so the shared Proxmox host is
# not pegged by every LXC converging on every 5-min cycle. It still refreshes
# the per-host apply timestamp, so AutoMitamaeApplyStale never false-fires.
#
# Canary gate (ADR 0009): the fleet phase runs ONLY when every canary host
# answered with proof that expected_sha succeeded on it —
#   success     with sha == expected_sha, or
#   up_to_date  with verified_sha == expected_sha (the runner's persisted
#               per-SHA record names expected_sha and its last attempt did
#               not fail; pre-0009 runners never emit verified_sha).
# Anything else HOLDS the fleet this cycle (metrics published, cycle exits 0,
# cron retries in 5 min): ssh_unreachable, lock_held, sha_mismatch, an
# up_to_date without a matching verified_sha. mitamae_fail / git_fetch_fail /
# invalid_command are FAILURES and abort the cycle as before. Before 0009 the
# transient set fell through to the fleet phase and an unverified up_to_date
# counted as success — both were paths that shipped a sha the canary had not
# validated (the isolated reproduction is recorded in ADR 0009).
#
# 2026-05-17 stability hardening (Phase 3 of stability rollout):
# canary deploy prevents fleet-wide propagation of cookbook bugs.
# Sibling alert AutoMitamaeCanaryFailing surfaces blocked rollouts.

set -uo pipefail

# AUTO_MITAMAE_ORCH_* overrides exist ONLY for the hermetic regression harness
# (cookbooks/auto-mitamae-target/test/run-state-scenarios.sh), which also
# shadows `ssh` on PATH. cron runs this script with a fixed environment, so
# production always uses the defaults.
LOCK_FILE="${AUTO_MITAMAE_ORCH_LOCK_FILE:-/var/lock/auto-mitamae-orchestrator.lock}"
TEXTFILE_DIR="${AUTO_MITAMAE_ORCH_TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
DRIFT_TEXTFILE="${TEXTFILE_DIR}/drift-checker.prom"
OUTPUT_TEXTFILE="${TEXTFILE_DIR}/auto-mitamae.prom"
HOSTS_JSON="${AUTO_MITAMAE_ORCH_HOSTS_JSON:-/etc/auto-mitamae/hosts.json}"
SSH_KEY="${AUTO_MITAMAE_ORCH_SSH_KEY:-/root/.ssh/orchestrator}"
SSH_KNOWN_HOSTS="${AUTO_MITAMAE_ORCH_SSH_KNOWN_HOSTS:-/root/.ssh/known_hosts.orchestrator}"

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    echo "orchestrator: previous cycle still in progress, skipping" >&2
    exit 0
fi

# Read expected SHA + last drift-checker outcome. The textfile lines look like:
#   setup_main_head_commit_info{commit="abc..."} 1
#   setup_main_head_check_status{result="ok"} 1
expected_sha=""
api_status=""
if [[ -f "${DRIFT_TEXTFILE}" ]]; then
    expected_sha=$(awk -F'"' '/^setup_main_head_commit_info{commit=/ {print $2; exit}' "${DRIFT_TEXTFILE}")
    api_status=$(awk -F'"' '/^setup_main_head_check_status{result=/ {print $2; exit}' "${DRIFT_TEXTFILE}")
fi

if [[ -z "${expected_sha}" || "${api_status}" != "ok" ]]; then
    echo "orchestrator: drift-checker SHA unavailable (api_status=${api_status:-missing}), skipping cycle" >&2
    # Do not overwrite the previous textfile — a stale-SHA skip is not the
    # same as a no-op cycle. drift-checker's own textfile carries the
    # api_failure indicator for Grafana to surface.
    exit 0
fi

if [[ ! -f "${HOSTS_JSON}" ]]; then
    echo "orchestrator: hosts.json not found at ${HOSTS_JSON}" >&2
    exit 1
fi

tmp_out=$(mktemp "${OUTPUT_TEXTFILE}.tmp.XXXXXX")
trap 'rm -f "${tmp_out}" "${OUTPUT_TEXTFILE}.pub"' EXIT

now=$(date +%s)

{
    echo "# HELP auto_mitamae_last_apply_status 1 = host's last apply ended with this status"
    echo "# TYPE auto_mitamae_last_apply_status gauge"
    echo "# HELP auto_mitamae_last_apply_drift_commits Commits behind origin/main when apply ran"
    echo "# TYPE auto_mitamae_last_apply_drift_commits gauge"
    echo "# HELP auto_mitamae_last_apply_duration_seconds Wall-clock time of last mitamae run on host"
    echo "# TYPE auto_mitamae_last_apply_duration_seconds gauge"
    echo "# HELP auto_mitamae_last_apply_timestamp_seconds Unix time orchestrator captured this status"
    echo "# TYPE auto_mitamae_last_apply_timestamp_seconds gauge"
    echo "# HELP auto_mitamae_last_apply_sha_info Per-host SHA after last apply"
    echo "# TYPE auto_mitamae_last_apply_sha_info gauge"
    echo "# HELP auto_mitamae_orchestrator_expected_sha_info SHA the orchestrator drove this cycle"
    echo "# TYPE auto_mitamae_orchestrator_expected_sha_info gauge"
    echo "# HELP auto_mitamae_canary_last_status 1 = canary host's last apply ended with this status"
    echo "# TYPE auto_mitamae_canary_last_status gauge"
    echo "# HELP auto_mitamae_canary_last_sha_info SHA the canary host last tried to apply"
    echo "# TYPE auto_mitamae_canary_last_sha_info gauge"
    echo "# HELP auto_mitamae_canary_gate 1 = canary gate verdict this cycle (pass = fleet phase ran, hold = retry next cycle, fail = cookbook failure)"
    echo "# TYPE auto_mitamae_canary_gate gauge"
    echo "auto_mitamae_orchestrator_expected_sha_info{commit=\"${expected_sha}\"} 1"
} > "${tmp_out}"

# Atomically publish the in-progress textfile after every host so node_exporter
# sees fresh per-host status even when the cron `timeout` later kills a long
# cycle (e.g. an overloaded canary apply hits its 300s per-host timeout and
# blows the cycle budget). Before this, the prom was written only at the final
# mv, so a cycle that never completed froze ALL metrics — the orchestrator
# looked dead while it was in fact still applying hosts, and the tail hosts'
# status went stale. cp-then-rename keeps a scrape from reading a half-written
# file. The .pub temp is cleaned by the EXIT trap.
publish() {
  cp "${tmp_out}" "${OUTPUT_TEXTFILE}.pub" && mv "${OUTPUT_TEXTFILE}.pub" "${OUTPUT_TEXTFILE}"
}

# Helper: apply mitamae-runner on one host. Populates LAST_STATUS for the
# caller (canary gate) and appends per-host metrics to ${tmp_out}.
#
# Note: there is intentionally NO per-cycle credential re-seed here. The
# earlier "Phase B-2 lazy re-seed" block was architecturally dead when run
# from this orchestrator host (CT 111): its probe ssh'd each LXC with the
# restricted forced-command `orchestrator` key, which returns
# invalid_command for `aws sts ...`, so the re-seed branch was ALWAYS taken;
# and bootstrap-lxc-creds is a PVE-host-only operator script (all steps are
# `ssh root@<pve> pct ...`), so from CT 111 it fails host-key verification
# every time. The block emitted bootstrap_lxc_creds_* = failed for all 18
# LXCs every cycle while doing no work. Real credential provisioning happens
# inside each LXC's own mitamae apply (ssh-keys cookbook fetches from SSM).
# bin/bootstrap-lxc-creds remains as a PVE-host one-shot operator tool.
apply_one_host() {
    local entry="$1"
    local host user role label cmd_start output rc status sha drift rdur verified_sha

    host=$(jq -r '.host'  <<<"${entry}")
    user=$(jq -r '.user'  <<<"${entry}")
    role=$(jq -r '.role'  <<<"${entry}")
    label=$(jq -r '.label' <<<"${entry}")

    cmd_start=$(date +%s)
    # ssh -n is critical: without it, ssh inherits parent stdin and consumes
    # pending lines, breaking outer while-read loops. PR #153 origin.
    #
    # `timeout 300` bounds a single host's apply: a host whose runner hangs
    # (e.g. an ES node blocking on a RED-cluster wait_cluster_ready) must not
    # consume the whole 600s cycle budget and starve the tail hosts or prevent
    # the final metrics mv — which froze auto-mitamae.prom for 11 days in the
    # 2026-05 incident (es-2 RED cluster → 5-min apply waits → cycle killed at
    # es-1 every time → metrics never refreshed). On timeout (ssh exits 124)
    # the no-status-line branch below marks the host ssh_unreachable and the
    # cycle continues to the next host.
    if output=$(timeout 300 ssh -n \
            -i "${SSH_KEY}" \
            -o BatchMode=yes \
            -o ConnectTimeout=5 \
            -o ServerAliveInterval=10 \
            -o ServerAliveCountMax=2 \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="${SSH_KNOWN_HOSTS}" \
            "${user}@${host}" "${role} ${expected_sha}" 2>&1); then
        :
    else
        rc=$?
        if ! grep -q 'status=' <<<"${output}"; then
            cmd_dur=$(( $(date +%s) - cmd_start ))
            output="status=ssh_unreachable duration=${cmd_dur} ssh_rc=${rc}"
        fi
    fi

    status=$(grep -oE 'status=[a-z_]+'   <<<"${output}" | head -1 | cut -d= -f2)
    # `sha=` is anchored on a preceding space/line-start so it cannot match
    # the tail of `verified_sha=`.
    sha=$(   grep -oE '(^| )sha=[a-f0-9]+' <<<"${output}" | head -1 | tr -d ' ' | cut -d= -f2)
    verified_sha=$(grep -oE 'verified_sha=[a-f0-9]+' <<<"${output}" | head -1 | cut -d= -f2)
    drift=$( grep -oE 'drift=[0-9]+'     <<<"${output}" | head -1 | cut -d= -f2)
    rdur=$(  grep -oE 'duration=[0-9]+'  <<<"${output}" | head -1 | cut -d= -f2)

    status=${status:-invalid_command}
    drift=${drift:-0}
    rdur=${rdur:-0}

    {
        echo "auto_mitamae_last_apply_status{host=\"${label}\",result=\"${status}\"} 1"
        echo "auto_mitamae_last_apply_drift_commits{host=\"${label}\"} ${drift}"
        echo "auto_mitamae_last_apply_duration_seconds{host=\"${label}\"} ${rdur}"
        echo "auto_mitamae_last_apply_timestamp_seconds{host=\"${label}\"} ${now}"
        if [[ -n "${sha}" ]]; then
            echo "auto_mitamae_last_apply_sha_info{host=\"${label}\",sha=\"${sha}\"} 1"
        fi
    } >> "${tmp_out}"

    # Export for caller (canary gate).
    LAST_STATUS="${status}"
    LAST_LABEL="${label}"
    LAST_SHA="${sha}"
    LAST_VERIFIED_SHA="${verified_sha}"
}

# Phase A: canary hosts. Apply first; the fleet phase runs only if EVERY
# canary host proved expected_sha succeeded on it (see header). A hard
# failure aborts the cycle; anything unproven holds it. The canary metrics
# (status + sha + timestamp + gate verdict) are still emitted so Grafana
# shows why the fleet did not move. Non-canary host metrics are NOT touched
# on abort/hold — they retain their prior state from the last fleet cycle.
canary_failed=0
canary_held=0
canary_failure_label=""
canary_failure_status=""
canary_hold_label=""
canary_hold_status=""

while IFS= read -r entry; do
    apply_one_host "${entry}"
    publish   # keep the prom fresh after each canary host
    verdict=hold
    case "${LAST_STATUS}" in
        success)
            [[ "${LAST_SHA}" == "${expected_sha}" ]] && verdict=pass
            ;;
        up_to_date)
            # Proof of a recorded success for THIS sha. A pre-0009 runner (no
            # verified_sha) or a verified_sha for another sha is unproven.
            [[ "${LAST_VERIFIED_SHA}" == "${expected_sha}" ]] && verdict=pass
            ;;
        mitamae_fail|git_fetch_fail|invalid_command)
            verdict=fail
            ;;
        *)
            # ssh_unreachable / lock_held / sha_mismatch: transient, auto-
            # recover next cycle — but the fleet must not move on a sha the
            # canary has not validated.
            verdict=hold
            ;;
    esac
    case "${verdict}" in
        fail)
            canary_failed=1
            canary_failure_label="${LAST_LABEL}"
            canary_failure_status="${LAST_STATUS}"
            ;;
        hold)
            canary_held=1
            canary_hold_label="${LAST_LABEL}"
            canary_hold_status="${LAST_STATUS}"
            ;;
    esac
done < <(jq -c '.[] | select(.canary == true)' "${HOSTS_JSON}")

# Always emit canary status metrics regardless of pass/hold/fail. expected_sha
# already in the textfile; canary_last_sha echoes it for Grafana joins.
# canary_last_status keeps its pre-0009 meaning (the raw runner status the
# AutoMitamaeCanaryFailing regex matches); canary_gate carries the verdict.
canary_overall_status="success"
gate_verdict="pass"
if [[ "${canary_failed}" -eq 1 ]]; then
    canary_overall_status="${canary_failure_status}"
    gate_verdict="fail"
elif [[ "${canary_held}" -eq 1 ]]; then
    canary_overall_status="${canary_hold_status}"
    gate_verdict="hold"
fi
{
    echo "auto_mitamae_canary_last_status{result=\"${canary_overall_status}\"} 1"
    echo "auto_mitamae_canary_last_sha_info{commit=\"${expected_sha}\"} 1"
    echo "auto_mitamae_canary_gate{result=\"${gate_verdict}\"} 1"
} >> "${tmp_out}"
publish

if [[ "${canary_failed}" -eq 1 ]]; then
    mv "${tmp_out}" "${OUTPUT_TEXTFILE}"
    trap - EXIT
    echo "orchestrator: canary ${canary_failure_label} FAILED (${canary_failure_status}) at expected_sha=${expected_sha} — aborting fleet rollout"
    exit 0
fi

if [[ "${canary_held}" -eq 1 ]]; then
    mv "${tmp_out}" "${OUTPUT_TEXTFILE}"
    trap - EXIT
    echo "orchestrator: canary ${canary_hold_label} unverified (${canary_hold_status}) at expected_sha=${expected_sha} — holding fleet rollout until next cycle"
    exit 0
fi

# Phase B: non-canary hosts (the fleet). publish after each so a cycle the
# cron `timeout` later kills still leaves every processed host's status fresh.
while IFS= read -r entry; do
    apply_one_host "${entry}"
    publish
done < <(jq -c '.[] | select(.canary != true)' "${HOSTS_JSON}")

mv "${tmp_out}" "${OUTPUT_TEXTFILE}"
trap - EXIT
echo "orchestrator: cycle complete at expected_sha=${expected_sha}"
