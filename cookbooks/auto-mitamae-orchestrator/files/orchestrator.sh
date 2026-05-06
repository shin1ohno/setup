#!/bin/bash
# orchestrator.sh — central auto-mitamae fleet orchestrator (Phase 2b).
#
# 1. Read drift-checker's last-observed main HEAD SHA from a sibling
#    textfile metric. Skip the cycle if drift-checker hasn't run yet OR its
#    last poll was an api_failure (no point pushing a stale SHA).
# 2. Iterate hosts.json. For each host, ssh-push `<role> <expected-sha>` —
#    the remote forced-command (mitamae-runner) parses this and runs
#    `mitamae local <role>` after verifying its origin/main matches the SHA.
# 3. Capture per-host status from the runner's one-line stdout, accumulate
#    into a tmp textfile, atomic-mv into place.
#
# Status enum (matches mitamae-runner.sh):
#   success | mitamae_fail | sha_mismatch | git_fetch_fail
#   | lock_held | invalid_command | ssh_unreachable
#
# ssh_unreachable is orchestrator-side: ssh exited non-zero AND the runner
# never produced a `status=` line. Anything else is the runner's verdict.

set -uo pipefail

LOCK_FILE="/var/lock/auto-mitamae-orchestrator.lock"
TEXTFILE_DIR="/var/lib/node_exporter/textfile"
DRIFT_TEXTFILE="${TEXTFILE_DIR}/drift-checker.prom"
OUTPUT_TEXTFILE="${TEXTFILE_DIR}/auto-mitamae.prom"
HOSTS_JSON="/etc/auto-mitamae/hosts.json"
SSH_KEY="/root/.ssh/orchestrator"
SSH_KNOWN_HOSTS="/root/.ssh/known_hosts.orchestrator"

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
trap 'rm -f "${tmp_out}"' EXIT

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
    echo "auto_mitamae_orchestrator_expected_sha_info{commit=\"${expected_sha}\"} 1"
} > "${tmp_out}"

# Iterate hosts.json. Each entry: {host, user, role, label}.
while IFS= read -r entry; do
    host=$(jq -r '.host'  <<<"${entry}")
    user=$(jq -r '.user'  <<<"${entry}")
    role=$(jq -r '.role'  <<<"${entry}")
    label=$(jq -r '.label' <<<"${entry}")

    cmd_start=$(date +%s)
    # ssh -n is critical: without it, ssh inherits parent stdin (the
    # process-substitution `< <(jq ...)` feeding the while-read loop) and
    # consumes pending lines, so subsequent iterations see EOF and the
    # second host is silently skipped. Classic bash trap — see bug
    # discovery in PR description.
    if output=$(ssh -n \
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
        # If output already has a status= token (runner emitted before exiting
        # non-zero), keep its verdict. Otherwise classify as ssh_unreachable.
        if ! grep -q 'status=' <<<"${output}"; then
            cmd_dur=$(( $(date +%s) - cmd_start ))
            output="status=ssh_unreachable duration=${cmd_dur} ssh_rc=${rc}"
        fi
    fi

    status=$(grep -oE 'status=[a-z_]+'   <<<"${output}" | head -1 | cut -d= -f2)
    sha=$(   grep -oE 'sha=[a-f0-9]+'    <<<"${output}" | head -1 | cut -d= -f2)
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
done < <(jq -c '.[]' "${HOSTS_JSON}")

mv "${tmp_out}" "${OUTPUT_TEXTFILE}"
trap - EXIT
echo "orchestrator: cycle complete at expected_sha=${expected_sha}"
