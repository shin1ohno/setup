#!/bin/bash
# drift-checker.sh — poll GitHub API for shin1ohno/setup main HEAD,
# write to textfile for the orchestrator (sibling cron) to consume.
#
# The HTTP code is recorded as a separate metric so a sustained 403/429/5xx
# is visible in Grafana — without this, a silent flatline on the SHA gauge
# is indistinguishable from "no commits since last poll".

set -uo pipefail

LOCK_FILE="/var/lock/auto-mitamae-drift-checker.lock"
TEXTFILE_DIR="/var/lib/node_exporter/textfile"
OUTPUT_TEXTFILE="${TEXTFILE_DIR}/drift-checker.prom"
GH_API="https://api.github.com/repos/shin1ohno/setup/commits/main"

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    exit 0
fi

# Probe with -w to surface the HTTP code even on 4xx/5xx (which curl -fsS
# would otherwise suppress to stderr). Two-line form: body, then code.
http_code="000"
body=""
response=$(curl -sS -w '\n%{http_code}' \
    -H 'Accept: application/vnd.github+json' \
    -H 'User-Agent: auto-mitamae-drift-checker/1' \
    "${GH_API}" 2>/dev/null) && rc=0 || rc=$?

if [[ ${rc} -eq 0 ]]; then
    http_code=$(tail -n1 <<<"${response}")
    body=$(head -n -1 <<<"${response}")
fi

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

if [[ "${http_code}" == "200" ]]; then
    sha=$(jq -r '.sha // empty' <<<"${body}" 2>/dev/null)
    if [[ -n "${sha}" ]]; then
        {
            echo "setup_main_head_commit_info{commit=\"${sha}\"} 1"
            echo "setup_main_head_check_status{result=\"ok\"} 1"
        } >> "${tmp_out}"
    else
        echo "setup_main_head_check_status{result=\"parse_failure\",code=\"${http_code}\"} 1" >> "${tmp_out}"
    fi
else
    echo "setup_main_head_check_status{result=\"api_failure\",code=\"${http_code}\"} 1" >> "${tmp_out}"
fi

mv "${tmp_out}" "${OUTPUT_TEXTFILE}"
trap - EXIT
