#!/usr/bin/env bash
# Idempotent Kibana per-host process liveness alerting setup (Phase 3).
#
# Reads expected-processes.json (host → [process.name, ...]) and creates
# one .es-query rule per (host, process) pair that fires when the
# `metrics-system.process-default` index has zero docs for that host +
# process combination in the last 10 minutes.
#
# Why 10 min lookback: PR #289 caps the system.process metricset to
# top-20-by-CPU + top-20-by-memory per scrape (OOM mitigation on small
# LXCs). On low-activity hosts (samba / memory / housekeeping) the
# scrape collects ~20 docs every 30s but the agent's flush + ingest
# rate is unpredictable; observed 1 doc per process per 10 min on
# idle samba (live ES probe 2026-05-10). 5-min window produced false
# positives for smbd / nmbd / dockerd. 10 min covers ~20 scrape
# cycles, brings false-positive rate to zero on the verified set.
#
# Action: Server Log connector (synthetics-server-log, created by Phase 2's
# setup-alerting.sh — must run that script first).
#
# Idempotency: each rule has a deterministic name based on host+process.
# Re-runs skip rules already present.
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
#   0 success — all rules exist (created or already-present)
#   1 connector not found (run setup-alerting.sh first)
#   2 expected-processes.json unreadable
#   3 one or more rule create calls failed

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

# --------------------------------------------------------------------------
# For each (host, process) pair, create a .es-query rule that alerts
# when process docs vanish from metrics-system.process-default.
# --------------------------------------------------------------------------

# Skip the "comment" key (documentation in the JSON file)
hosts="$(jq -r 'to_entries[] | select(.key != "comment") | .key' "${PROCESSES_JSON}")"

failures=0
created=0
existing=0

while IFS= read -r host; do
    [[ -z "${host}" ]] && continue
    processes="$(jq -r --arg h "${host}" '.[$h][]' "${PROCESSES_JSON}")"

    while IFS= read -r process; do
        [[ -z "${process}" ]] && continue

        rule_name="${RULE_NAME_PREFIX}: ${host} / ${process}"
        echo "  ${rule_name}..."

        # Search for existing rule by exact name match
        # Wrap the whole rule_name in URL-encoded quotes via search field
        encoded_name="$(echo -n "\"${rule_name}\"" | jq -sRr @uri)"
        existing_id="$(curl_kib \
            "${KIBANA_HOST}/api/alerting/rules/_find?per_page=100&search_fields=name&search=${encoded_name}" \
            | jq -r --arg n "${rule_name}" \
                '.data[]? | select(.name == $n) | .id' | head -1)"

        if [[ -n "${existing_id}" ]]; then
            echo "    exists: ${existing_id}"
            existing=$(( existing + 1 ))
            continue
        fi

        # KQL filter for the .es-query rule.
        kql="host.name : \"${host}\" and process.name : \"${process}\""

        # POST the new rule
        response="$(curl_kib -X POST "${KIBANA_HOST}/api/alerting/rule" \
            -d "$(jq -n \
                --arg name "${rule_name}" \
                --arg connector_id "${connector_id}" \
                --arg host "${host}" \
                --arg process "${process}" \
                --arg kql "${kql}" '{
                name: $name,
                rule_type_id: ".es-query",
                consumer: "alerts",
                schedule: { interval: "1m" },
                tags: ["liveness", "phase3", $host],
                params: {
                    searchType: "esQuery",
                    timeField: "@timestamp",
                    timeWindowSize: 10,
                    timeWindowUnit: "m",
                    threshold: [1],
                    thresholdComparator: "<",
                    size: 100,
                    index: ["metrics-system.process-default"],
                    esQuery: ({
                        query: {
                            bool: {
                                filter: [
                                    { term: { "host.name": $host } },
                                    { term: { "process.name": $process } }
                                ]
                            }
                        }
                    } | tojson),
                    aggType: "count",
                    groupBy: "all"
                },
                actions: [{
                    id: $connector_id,
                    group: "query matched",
                    params: {
                        level: "warn",
                        message: "Process DOWN: \($process) not seen on \($host) in the last 10 min (zero metrics-system.process docs)."
                    },
                    frequency: {
                        summary: false,
                        notify_when: "onActionGroupChange",
                        throttle: null
                    }
                }]
            }')")"

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

echo
echo "Process liveness rules: created=${created} existing=${existing} failures=${failures}"

if [[ ${failures} -gt 0 ]]; then
    exit 3
fi
