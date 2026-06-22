#!/usr/bin/env bash
# Idempotent Kibana saved-objects importer for the RTX overview v2 dashboard.
#
# Imports each NDJSON in this script's `saved-objects/` directory via the
# Kibana saved-objects _import API with overwrite=true so re-runs are safe.
#
# Environment:
#   KIBANA_HOST       — Kibana base URL (default: http://localhost:5601)
#   KIBANA_USER       — Kibana basic-auth username (required)
#   KIBANA_PASSWORD   — Kibana basic-auth password (required)
#   READY_TIMEOUT     — seconds to wait for Kibana /api/status (default: 120)
#   READY_INTERVAL    — poll interval seconds (default: 5)
#
# Exit codes:
#   0 success — every saved-object import returned .success == true
#   1 generic failure (network, JSON parse, missing dependency)
#   2 Kibana never reached "available" within READY_TIMEOUT
#   3 at least one import returned .success == false

set -euo pipefail

KIBANA_HOST="${KIBANA_HOST:-http://localhost:5601}"
KIBANA_USER="${KIBANA_USER:?KIBANA_USER must be set}"
KIBANA_PASSWORD="${KIBANA_PASSWORD:?KIBANA_PASSWORD must be set}"
READY_TIMEOUT="${READY_TIMEOUT:-120}"
READY_INTERVAL="${READY_INTERVAL:-5}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAVED_OBJECTS_DIR="${SCRIPT_DIR}/saved-objects"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not on PATH" >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required but not on PATH" >&2
    exit 1
fi

if [[ ! -d "${SAVED_OBJECTS_DIR}" ]]; then
    echo "ERROR: saved-objects directory not found: ${SAVED_OBJECTS_DIR}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Phase 1: wait for Kibana to report status=available
# ---------------------------------------------------------------------------
echo "Waiting for Kibana at ${KIBANA_HOST} (timeout ${READY_TIMEOUT}s)..."

deadline=$(( $(date +%s) + READY_TIMEOUT ))
while :; do
    now=$(date +%s)
    if [[ ${now} -ge ${deadline} ]]; then
        echo "ERROR: Kibana did not become available within ${READY_TIMEOUT}s" >&2
        exit 2
    fi

    # /api/status is unauthenticated for status checks since 8.x.
    status_body="$(curl -sS --max-time 10 \
        -u "${KIBANA_USER}:${KIBANA_PASSWORD}" \
        "${KIBANA_HOST}/api/status" 2>/dev/null || true)"

    if [[ -n "${status_body}" ]]; then
        level="$(echo "${status_body}" | jq -r '.status.overall.level // empty' 2>/dev/null || true)"
        if [[ "${level}" == "available" ]]; then
            echo "Kibana is available."
            break
        fi
    fi

    sleep "${READY_INTERVAL}"
done

# ---------------------------------------------------------------------------
# Phase 2: import each NDJSON. Order matters — index-pattern (data view)
# and visualization references must exist before the dashboard, which
# references them. Import in dependency order:
#   1. rtx-discover.ndjson           — declares index-pattern + saved search
#   2. rtx-lens-*.ndjson             — Lens visualizations
#   3. rtx-maps-geo.ndjson           — Map (uses index-pattern)
#   4. rtx-overview-v2.ndjson        — Dashboard (references all rtx-lens-* + map)
# ---------------------------------------------------------------------------

import_file() {
    local file="$1"
    local file_basename
    file_basename="$(basename "${file}")"

    echo "Importing ${file_basename}..."
    local response
    response="$(curl -sS --max-time 60 \
        -X POST \
        -H "kbn-xsrf: true" \
        -u "${KIBANA_USER}:${KIBANA_PASSWORD}" \
        -F "file=@${file}" \
        "${KIBANA_HOST}/api/saved_objects/_import?overwrite=true&createNewCopies=false")"

    local success
    success="$(echo "${response}" | jq -r '.success // empty' 2>/dev/null || true)"

    if [[ "${success}" != "true" ]]; then
        echo "ERROR: import failed for ${file_basename}" >&2
        echo "Response: ${response}" >&2
        return 1
    fi

    local count
    count="$(echo "${response}" | jq -r '.successCount // 0')"
    echo "  ${file_basename}: imported ${count} object(s)."
}

# Explicit ordering — dashboard last so its references resolve.
ordered=(
    "${SAVED_OBJECTS_DIR}/rtx-discover.ndjson"
    # IKE/IPsec VPN event saved search (security panel — Grafana rtx-logs parity)
    "${SAVED_OBJECTS_DIR}/rtx-discover-ike.ndjson"
    # v2 Lens objects: metrics
    "${SAVED_OBJECTS_DIR}/rtx-lens-metric-total-events.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-metric-unique-src.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-metric-reject.ndjson"
    # v2 Lens objects: donuts (categorical breakdowns)
    "${SAVED_OBJECTS_DIR}/rtx-lens-donut-severity.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-donut-action.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-donut-direction.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-donut-country.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-donut-top-src.ndjson"
    # v2 Lens objects: time series + heatmap + stacked bar
    "${SAVED_OBJECTS_DIR}/rtx-lens-events-over-time.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-line-unique-src-over-time.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-heatmap-hour-router.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-stacked-country-over-time.ndjson"
    # Map + dashboard
    "${SAVED_OBJECTS_DIR}/rtx-maps-geo.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-overview-v2.ndjson"
    # RTX SNMP metrics dashboard (elastic-agent prometheus.collector federation
    # of the snmp-rtx job). Data view first, then Lens panels, dashboard last so
    # references resolve. Panels break down by prometheus.labels.router, so new
    # routers added to the snmp-rtx job appear automatically.
    "${SAVED_OBJECTS_DIR}/rtx-snmp-dataview.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-snmp-cpu.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-snmp-memory.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-snmp-temperature.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-snmp-throughput.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-snmp-errors.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-snmp-status-table.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-snmp-iface-table.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-snmp-routers.ndjson"
    # WLX WiFi AP syslog (logs-wlx-default) — data view + recent-events
    # Discover saved search. Single file declares both (index-pattern first,
    # search second) so references resolve within the one import.
    "${SAVED_OBJECTS_DIR}/wlx-discover.ndjson"
    # Self-heal observer open-issue state (self-heal-state index). Single file
    # declares the data view first, then the Lens table + metric, then the
    # dashboard last, so all references resolve within the one import.
    # Source: cookbooks/self-heal-observer.
    "${SAVED_OBJECTS_DIR}/self-heal-issues.ndjson"
)

failures=0
for f in "${ordered[@]}"; do
    if [[ ! -f "${f}" ]]; then
        echo "ERROR: missing NDJSON: ${f}" >&2
        failures=$(( failures + 1 ))
        continue
    fi
    if ! import_file "${f}"; then
        failures=$(( failures + 1 ))
    fi
done

if [[ ${failures} -gt 0 ]]; then
    echo "ERROR: ${failures} import(s) failed" >&2
    exit 3
fi

echo "All saved objects imported successfully."
