#!/usr/bin/env bash
# Idempotent Kibana saved-objects importer for the RTX-logs scaffold.
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
#   2. rtx-lens-*.ndjson             — Lens visualizations + Maps source layer
#   3. rtx-maps-geo.ndjson           — Map (uses index-pattern)
#   4. rtx-overview.ndjson           — Original 5-panel scaffold dashboard
#   5. rtx-overview-v2.ndjson        — Comprehensive 17-panel dashboard
#                                      (references all rtx-lens-* + map)
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

# Explicit ordering — dashboards last so their references resolve.
ordered=(
    "${SAVED_OBJECTS_DIR}/rtx-discover.ndjson"
    # Original 5-panel scaffold lenses (Phase 5, PR #238)
    "${SAVED_OBJECTS_DIR}/rtx-lens-top-src.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-top-dst-port.ndjson"
    # v2 Lens objects: metrics
    "${SAVED_OBJECTS_DIR}/rtx-lens-metric-total-events.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-metric-unique-src.ndjson"
    # v2 Lens objects: donuts (categorical breakdowns)
    "${SAVED_OBJECTS_DIR}/rtx-lens-donut-severity.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-donut-facility.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-donut-action.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-donut-protocol.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-donut-interface.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-donut-direction.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-donut-phase.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-donut-router.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-donut-country.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-donut-top-src.ndjson"
    # v2 Lens objects: time series + heatmap + stacked bar
    "${SAVED_OBJECTS_DIR}/rtx-lens-line-unique-src-over-time.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-heatmap-hour-router.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-lens-stacked-country-over-time.ndjson"
    # Maps + dashboards
    "${SAVED_OBJECTS_DIR}/rtx-maps-geo.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-overview.ndjson"
    "${SAVED_OBJECTS_DIR}/rtx-overview-v2.ndjson"

    # ---- EC2 access log dashboard ----
    # Index pattern covers logs-system.{auth,syslog,system}-* via Elastic Agent
    "${SAVED_OBJECTS_DIR}/ec2-index-pattern.ndjson"
    # Lens objects: metrics
    "${SAVED_OBJECTS_DIR}/ec2-lens-metric-total-auth.ndjson"
    "${SAVED_OBJECTS_DIR}/ec2-lens-metric-unique-src.ndjson"
    "${SAVED_OBJECTS_DIR}/ec2-lens-metric-failed-logins.ndjson"
    # Lens objects: donuts (categorical breakdowns)
    "${SAVED_OBJECTS_DIR}/ec2-lens-donut-country.ndjson"
    "${SAVED_OBJECTS_DIR}/ec2-lens-donut-event-action.ndjson"
    "${SAVED_OBJECTS_DIR}/ec2-lens-donut-process.ndjson"
    "${SAVED_OBJECTS_DIR}/ec2-lens-donut-top-src.ndjson"
    # Lens objects: time series + heatmap + stacked bar
    "${SAVED_OBJECTS_DIR}/ec2-lens-timeseries-auth.ndjson"
    "${SAVED_OBJECTS_DIR}/ec2-lens-timeseries-sudo.ndjson"
    "${SAVED_OBJECTS_DIR}/ec2-lens-heatmap-hour-event.ndjson"
    "${SAVED_OBJECTS_DIR}/ec2-lens-stacked-username.ndjson"
    # Maps + dashboard
    "${SAVED_OBJECTS_DIR}/ec2-maps-geo.ndjson"
    "${SAVED_OBJECTS_DIR}/ec2-access-overview.ndjson"

    # ---- Grafana-ported RTX routers metrics dashboard ----
    # Reads from metrics-prometheus.collector-* (Stream T deliverable).
    # Panels show "no data" until Prometheus metrics flow into ES.
    "${SAVED_OBJECTS_DIR}/grafana-port-rtx-routers-data-view.ndjson"
    # Lens visualizations (12 panels): stats first, then timeseries, table
    "${SAVED_OBJECTS_DIR}/grafana-port-rtx-routers-uptime.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-rtx-routers-firmware.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-rtx-routers-hostname.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-rtx-routers-temperature.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-rtx-routers-lan1-bandwidth.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-rtx-routers-lan2-bandwidth.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-rtx-routers-bridge1-bandwidth.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-rtx-routers-input-errors.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-rtx-routers-output-errors.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-rtx-routers-cpu.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-rtx-routers-memory.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-rtx-routers-interface-table.ndjson"
    # Dashboard last (references all 12 lens objects above)
    "${SAVED_OBJECTS_DIR}/grafana-port-rtx-routers-overview.ndjson"

    # ---- Auto-mitamae fleet dashboard (Phase 5b, Stream V) ----
    "${SAVED_OBJECTS_DIR}/auto-mitamae-lens-hosts-success.ndjson"
    "${SAVED_OBJECTS_DIR}/auto-mitamae-lens-hosts-hard-fail.ndjson"
    "${SAVED_OBJECTS_DIR}/auto-mitamae-lens-hosts-transient.ndjson"
    "${SAVED_OBJECTS_DIR}/auto-mitamae-lens-hosts-active.ndjson"
    "${SAVED_OBJECTS_DIR}/auto-mitamae-lens-max-duration.ndjson"
    "${SAVED_OBJECTS_DIR}/auto-mitamae-lens-max-drift.ndjson"
    "${SAVED_OBJECTS_DIR}/auto-mitamae-lens-per-host.ndjson"
    "${SAVED_OBJECTS_DIR}/auto-mitamae-overview.ndjson"

    # ---- Grafana-ported Proxmox metrics dashboard ----
    "${SAVED_OBJECTS_DIR}/grafana-port-proxmox-resource-table.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-proxmox-node-cpu-history.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-proxmox-node-cpu-current.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-proxmox-node-cpu-limit.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-proxmox-node-memory-history.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-proxmox-node-memory-current.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-proxmox-node-memory-bytes.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-proxmox-guests-cpu.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-proxmox-guests-memory.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-proxmox-storage-usage.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-proxmox-storage-allocation.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-proxmox-lxc-disk.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-proxmox-network-io.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-proxmox-disk-io.ndjson"
    "${SAVED_OBJECTS_DIR}/grafana-port-proxmox-overview.ndjson"
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
