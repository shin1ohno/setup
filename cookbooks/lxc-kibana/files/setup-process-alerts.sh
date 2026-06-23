#!/usr/bin/env bash
# Idempotent Kibana per-host process liveness alerting setup (Phase 3).
#
# Reads expected-processes.json (host -> [process.name, ...]) and creates one
# .es-query rule per (host, process) pair that fires when the
# `metrics-system.process-default` index has zero docs for that host + process
# combination in the rule's lookback window.
#
# Per-host lookback window (`_window_minutes` in expected-processes.json):
#   default 5 min for fast detection; low-activity hosts that emit ~1 doc per
#   process per 10 min (samba, memory) keep 10 min to avoid flapping false
#   positives. Background: PR #289 caps the system.process metricset to
#   top-20-by-CPU + top-20-by-memory per scrape (OOM mitigation), so an idle
#   process can be absent from many consecutive scrapes — a 5-min window flaps
#   for smbd / nmbd / dockerd on those hosts (live ES probe 2026-05-10), a
#   10-min window brings their false-positive rate to zero. Active hosts have no
#   such gap, so 5 min is safe and halves their detection latency.
#
# Action: Server Log connector (synthetics-server-log, created by Phase 2's
# setup-alerting.sh — must run that script first).
#
# Idempotency:
#   - rules keyed by deterministic name (host+process)
#   - existing rule with a stale lookback window is UPDATED in place (so a
#     _window_minutes change propagates to the live rules, not just new ones)
#   - PRUNE phase3 rules whose (host, process) pair is no longer expected (so
#     renaming a process retires the old rule instead of orphaning it).
#
# Environment:
#   KIBANA_HOST       — Kibana base URL (default: http://localhost:5601)
#   KIBANA_USER       — Kibana basic-auth username (required)
#   KIBANA_PASSWORD   — Kibana basic-auth password (required)
#
# Usage (post-deploy from inside CT 115, AFTER setup-alerting.sh):
#   KIBANA_USER=elastic KIBANA_PASSWORD=... ./setup-process-alerts.sh
#
# Exit codes:
#   0 success   1 connector not found   2 json unreadable   3 a rule op failed

set -euo pipefail

KIBANA_HOST="${KIBANA_HOST:-http://localhost:5601}"
KIBANA_USER="${KIBANA_USER:?KIBANA_USER must be set}"
KIBANA_PASSWORD="${KIBANA_PASSWORD:?KIBANA_PASSWORD must be set}"

CONNECTOR_NAME="synthetics-server-log"
RULE_NAME_PREFIX="Process down"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROCESSES_JSON="${SCRIPT_DIR}/expected-processes.json"

if [[ ! -r "${PROCESSES_JSON}" ]]; then
    echo "ERROR: cannot read ${PROCESSES_JSON}" >&2
    exit 2
fi

curl_kib() {
    curl -sS --max-time 30 \
        -u "${KIBANA_USER}:${KIBANA_PASSWORD}" \
        -H "kbn-xsrf: true" \
        -H "content-type: application/json" \
        "$@"
}

# Per-host lookback window (minutes): _window_minutes[host] else _default else 5.
window_for_host() {
    jq -r --arg h "$1" \
        '(._window_minutes[$h] // ._window_minutes["_default"] // 5)' \
        "${PROCESSES_JSON}"
}

# Emit the rule JSON body. mode=create adds the immutable rule_type_id/consumer
# (POST); mode=update omits them (PUT /api/alerting/rule/<id>).
rule_body() {
    local name="$1" host="$2" process="$3" window="$4" mode="$5"
    local kql="host.name : \"${host}\" and process.name : \"${process}\""
    jq -n \
        --arg name "${name}" \
        --arg connector_id "${connector_id}" \
        --arg host "${host}" \
        --arg process "${process}" \
        --arg kql "${kql}" \
        --argjson win "${window}" \
        --arg mode "${mode}" '
        {
            name: $name,
            schedule: { interval: "1m" },
            tags: ["liveness", "phase3", $host],
            params: {
                searchType: "esQuery",
                timeField: "@timestamp",
                timeWindowSize: $win,
                timeWindowUnit: "m",
                threshold: [1],
                thresholdComparator: "<",
                size: 100,
                index: ["metrics-system.process-default"],
                esQuery: ({
                    query: { bool: { filter: [
                        { term: { "host.name": $host } },
                        { term: { "process.name": $process } }
                    ] } }
                } | tojson),
                aggType: "count",
                groupBy: "all"
            },
            actions: [{
                id: $connector_id,
                group: "query matched",
                params: {
                    level: "warn",
                    message: "Process DOWN: \($process) not seen on \($host) in the last \($win|tostring) min (zero metrics-system.process docs)."
                },
                frequency: { summary: false, notify_when: "onActionGroupChange", throttle: null }
            }]
        }
        | if $mode == "create" then . + { rule_type_id: ".es-query", consumer: "alerts" } else . end
    '
}

# --------------------------------------------------------------------------
# Look up the Server Log connector (created by setup-alerting.sh)
# --------------------------------------------------------------------------
connector_id="$(curl_kib "${KIBANA_HOST}/api/actions/connectors" \
    | jq -r --arg name "${CONNECTOR_NAME}" \
        '.[] | select(.name == $name) | .id' | head -1)"

if [[ -z "${connector_id}" ]]; then
    echo "ERROR: connector '${CONNECTOR_NAME}' not found." >&2
    echo "       Run cookbooks/lxc-kibana/files/setup-alerting.sh first." >&2
    exit 1
fi

echo "Using connector: ${connector_id}"
echo

# Host keys only: skip the "comment" doc key and any "_"-prefixed config key
# (e.g. _window_minutes).
hosts="$(jq -r 'to_entries[]
    | select(.key != "comment" and (.key | startswith("_") | not))
    | .key' "${PROCESSES_JSON}")"

failures=0
created=0
updated=0
existing=0

while IFS= read -r host; do
    [[ -z "${host}" ]] && continue
    win="$(window_for_host "${host}")"
    processes="$(jq -r --arg h "${host}" '.[$h][]' "${PROCESSES_JSON}")"

    while IFS= read -r process; do
        [[ -z "${process}" ]] && continue

        rule_name="${RULE_NAME_PREFIX}: ${host} / ${process}"
        echo "  ${rule_name} (window=${win}m)..."

        encoded_name="$(echo -n "\"${rule_name}\"" | jq -sRr @uri)"
        existing_id="$(curl_kib \
            "${KIBANA_HOST}/api/alerting/rules/_find?per_page=100&search_fields=name&search=${encoded_name}" \
            | jq -r --arg n "${rule_name}" \
                '.data[]? | select(.name == $n) | .id' | head -1)"

        if [[ -n "${existing_id}" ]]; then
            cur_win="$(curl_kib "${KIBANA_HOST}/api/alerting/rule/${existing_id}" \
                | jq -r '.params.timeWindowSize // empty')"
            if [[ "${cur_win}" == "${win}" ]]; then
                echo "    exists: ${existing_id}"
                existing=$(( existing + 1 ))
                continue
            fi
            # Window drifted — update the rule in place.
            response="$(curl_kib -X PUT "${KIBANA_HOST}/api/alerting/rule/${existing_id}" \
                -d "$(rule_body "${rule_name}" "${host}" "${process}" "${win}" update)")"
            if [[ -n "$(echo "${response}" | jq -r '.id // empty')" ]]; then
                echo "    updated window ${cur_win}->${win}: ${existing_id}"
                updated=$(( updated + 1 ))
            else
                echo "    ERROR: update failed: ${response}" >&2
                failures=$(( failures + 1 ))
            fi
            continue
        fi

        response="$(curl_kib -X POST "${KIBANA_HOST}/api/alerting/rule" \
            -d "$(rule_body "${rule_name}" "${host}" "${process}" "${win}" create)")"
        new_id="$(echo "${response}" | jq -r '.id // empty')"
        if [[ -z "${new_id}" ]]; then
            echo "    ERROR: create failed: ${response}" >&2
            failures=$(( failures + 1 ))
            continue
        fi
        echo "    created: ${new_id}"
        created=$(( created + 1 ))
    done <<< "${processes}"
done <<< "${hosts}"

# --------------------------------------------------------------------------
# Prune: delete phase3 process-liveness rules whose (host, process) pair is no
# longer in expected-processes.json. Renaming a process changes the rule NAME;
# without pruning the old-named rule lingers and fires forever as a false
# positive. Scoped strictly to rules tagged "phase3".
# --------------------------------------------------------------------------
expected_names="$(
    while IFS= read -r host; do
        [[ -z "${host}" ]] && continue
        while IFS= read -r process; do
            [[ -z "${process}" ]] && continue
            echo "${RULE_NAME_PREFIX}: ${host} / ${process}"
        done <<< "$(jq -r --arg h "${host}" '.[$h][]' "${PROCESSES_JSON}")"
    done <<< "${hosts}" | sort -u
)"

pruned=0
all_phase3="$(curl_kib "${KIBANA_HOST}/api/alerting/rules/_find?per_page=200" \
    | jq -r '.data[]? | select(.tags | index("phase3")) | "\(.id)\t\(.name)"')"

while IFS=$'\t' read -r rid rname; do
    [[ -z "${rid}" ]] && continue
    if ! grep -qxF "${rname}" <<< "${expected_names}"; then
        echo "  pruning stale rule: ${rname} (${rid})"
        if curl_kib -X DELETE "${KIBANA_HOST}/api/alerting/rule/${rid}" >/dev/null; then
            pruned=$(( pruned + 1 ))
        else
            echo "    ERROR: prune delete failed for ${rid}" >&2
            failures=$(( failures + 1 ))
        fi
    fi
done <<< "${all_phase3}"

echo
echo "Process liveness rules: created=${created} updated=${updated} existing=${existing} pruned=${pruned} failures=${failures}"

if [[ ${failures} -gt 0 ]]; then
    exit 3
fi
