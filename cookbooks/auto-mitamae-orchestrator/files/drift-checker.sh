#!/bin/bash
# drift-checker.sh — resolve shin1ohno/setup main HEAD SHA and write it to a
# node_exporter textfile for the orchestrator (sibling cron) to consume.
#
# Uses `git ls-remote` (Git smart-HTTP), NOT the GitHub REST API: the REST
# API meters unauthenticated requests at 60/hr per source IP, which this
# every-2-min cron plus the rest of the fleet sharing one NAT egress IP
# regularly exhausted (HTTP 403 → result="api_failure" → the orchestrator
# skips the cycle, pinning a stale expected_sha). git smart-HTTP is not
# metered against that budget and needs no token. The result label
# (ok | api_failure) is the contract the orchestrator gates on and the
# AutoMitamae* alert rules match.

set -uo pipefail

LOCK_FILE="/var/lock/auto-mitamae-drift-checker.lock"
TEXTFILE_DIR="/var/lib/node_exporter/textfile"
OUTPUT_TEXTFILE="${TEXTFILE_DIR}/drift-checker.prom"
GH_REPO="https://github.com/shin1ohno/setup"

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    exit 0
fi

# Resolve origin/main HEAD via Git smart-HTTP. A network/DNS/repo failure
# leaves sha empty (ls-remote prints nothing / non-zero), which maps to
# result="api_failure" below — same contract as the previous REST probe.
sha=$(git ls-remote "${GH_REPO}" main 2>/dev/null \
    | awk '/refs\/heads\/main$/ {print $1; exit}')

tmp_out=$(mktemp "${OUTPUT_TEXTFILE}.tmp.XXXXXX")
trap 'rm -f "${tmp_out}"' EXIT

now=$(date +%s)

{
    echo "# HELP setup_main_head_commit_info Latest origin/main commit observed"
    echo "# TYPE setup_main_head_commit_info gauge"
    echo "# HELP setup_main_head_check_status Drift-checker last poll outcome"
    echo "# TYPE setup_main_head_check_status gauge"
    echo "# HELP setup_main_head_check_timestamp_seconds Unix time of last poll attempt"
    echo "# TYPE setup_main_head_check_timestamp_seconds gauge"
    echo "setup_main_head_check_timestamp_seconds ${now}"
} > "${tmp_out}"

if [[ "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
    {
        echo "setup_main_head_commit_info{commit=\"${sha}\"} 1"
        echo "setup_main_head_check_status{result=\"ok\"} 1"
    } >> "${tmp_out}"
else
    # Empty / malformed SHA: ls-remote failed (DNS, network, repo gone). This
    # is the same result label the orchestrator gates on (api_status != ok →
    # skip cycle) and the alert rule matches (result!="ok").
    echo "setup_main_head_check_status{result=\"api_failure\"} 1" >> "${tmp_out}"
fi

mv "${tmp_out}" "${OUTPUT_TEXTFILE}"
trap - EXIT
