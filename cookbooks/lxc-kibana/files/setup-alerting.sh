#!/usr/bin/env bash
# Idempotent Kibana Uptime/Synthetics alerting setup.
#
# Creates:
#   1. Server Log connector  — writes alert events to Kibana's own log
#                              (visible via `journalctl -u kibana`)
#   2. Uptime Status rule    — fires when any monitor is down for 5 consecutive
#                              checks (~5 min); action = log via #1
#   3. Uptime TLS rule       — fires when any HTTPS monitor's cert is within
#                              30 days of expiry; action = log via #1
#
# Rule type choice: standalone Elastic Agent's Synthetics integration ships
# probe results to `synthetics-*` data streams (which the Uptime app reads
# via the `xpack.uptime.heartbeatIndices` setting we set to
# `heartbeat-*,synthetics-*`). The legacy `xpack.uptime.alerts.*` rule
# types query that same setting; the newer `xpack.synthetics.alerts.*`
# rule types only see Fleet-managed monitors registered via the Synthetics
# UI — so they would never fire on our standalone probes.
#
# Operator alert channel choice (2026-05-10): journal-only. No Slack/SMTP.
# Server Log connector is the "free" Kibana built-in that requires zero
# external config — events surface in `journalctl -u kibana --since`.
#
# Idempotency: each PUT/POST first checks if the entity already exists
# (by name) and skips create. Re-runs are safe.
#
# Environment:
#   KIBANA_HOST       — Kibana base URL (default: http://localhost:5601)
#   KIBANA_USER       — Kibana basic-auth username (required)
#   KIBANA_PASSWORD   — Kibana basic-auth password (required)
#
# Usage (post-deploy from inside CT 115):
#   KIBANA_USER=elastic KIBANA_PASSWORD=... ./setup-alerting.sh
#
# Exit codes:
#   0 success — all 3 resources exist (created or already-present)
#   1 failure — API call returned unexpected status

set -euo pipefail

KIBANA_HOST="${KIBANA_HOST:-http://localhost:5601}"
KIBANA_USER="${KIBANA_USER:?KIBANA_USER must be set}"
KIBANA_PASSWORD="${KIBANA_PASSWORD:?KIBANA_PASSWORD must be set}"

CONNECTOR_NAME="synthetics-server-log"
STATUS_RULE_NAME="Uptime monitor down (Phase 2 liveness)"
TLS_RULE_NAME="Uptime TLS cert expiry (Phase 2 liveness)"

curl_kib() {
    curl -sS --max-time 30 \
        -u "${KIBANA_USER}:${KIBANA_PASSWORD}" \
        -H "kbn-xsrf: true" \
        -H "content-type: application/json" \
        "$@"
}

# --------------------------------------------------------------------------
# 1. Server Log connector
# --------------------------------------------------------------------------
echo "[1/3] Server Log connector (${CONNECTOR_NAME})..."

existing_connector_id="$(curl_kib "${KIBANA_HOST}/api/actions/connectors" \
    | jq -r --arg name "${CONNECTOR_NAME}" \
        '.[] | select(.name == $name) | .id' | head -1)"

if [[ -n "${existing_connector_id}" ]]; then
    echo "  exists: ${existing_connector_id}"
    connector_id="${existing_connector_id}"
else
    response="$(curl_kib -X POST "${KIBANA_HOST}/api/actions/connector" \
        -d "$(jq -n --arg name "${CONNECTOR_NAME}" '{
            name: $name,
            connector_type_id: ".server-log",
            config: {},
            secrets: {}
        }')")"
    connector_id="$(echo "${response}" | jq -r '.id // empty')"
    if [[ -z "${connector_id}" ]]; then
        echo "ERROR: connector create failed: ${response}" >&2
        exit 1
    fi
    echo "  created: ${connector_id}"
fi

# --------------------------------------------------------------------------
# 2. Synthetics monitor-status rule
# --------------------------------------------------------------------------
echo "[2/3] Uptime Status rule (${STATUS_RULE_NAME})..."

existing_status_rule="$(curl_kib "${KIBANA_HOST}/api/alerting/rules/_find?per_page=100&search_fields=name&search=${STATUS_RULE_NAME// /+}" \
    | jq -r --arg name "${STATUS_RULE_NAME}" \
        '.data[]? | select(.name == $name) | .id' | head -1)"

if [[ -n "${existing_status_rule}" ]]; then
    echo "  exists: ${existing_status_rule}"
else
    response="$(curl_kib -X POST "${KIBANA_HOST}/api/alerting/rule" \
        -d "$(jq -n \
            --arg name "${STATUS_RULE_NAME}" \
            --arg connector_id "${connector_id}" '{
            name: $name,
            rule_type_id: "xpack.uptime.alerts.monitorStatus",
            consumer: "uptime",
            schedule: { interval: "1m" },
            tags: ["liveness", "phase2"],
            params: {
                numTimes: 2,
                timerangeUnit: "m",
                timerangeCount: 5,
                shouldCheckStatus: true,
                shouldCheckAvailability: false,
                filters: { tags: [], "observer.geo.name": [], "url.port": [], "monitor.type": [] },
                search: ""
            },
            actions: [{
                id: $connector_id,
                group: "xpack.uptime.alerts.actionGroups.monitorStatus",
                params: {
                    level: "warn",
                    message: "Uptime monitor DOWN: {{context.monitorName}} ({{context.monitorUrl}}) — {{context.reason}}"
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
        echo "ERROR: status rule create failed: ${response}" >&2
        exit 1
    fi
    echo "  created: ${new_id}"
fi

# --------------------------------------------------------------------------
# 3. Synthetics TLS cert-expiry rule
# --------------------------------------------------------------------------
echo "[3/3] Uptime TLS rule (${TLS_RULE_NAME})..."

existing_tls_rule="$(curl_kib "${KIBANA_HOST}/api/alerting/rules/_find?per_page=100&search_fields=name&search=${TLS_RULE_NAME// /+}" \
    | jq -r --arg name "${TLS_RULE_NAME}" \
        '.data[]? | select(.name == $name) | .id' | head -1)"

if [[ -n "${existing_tls_rule}" ]]; then
    echo "  exists: ${existing_tls_rule}"
else
    response="$(curl_kib -X POST "${KIBANA_HOST}/api/alerting/rule" \
        -d "$(jq -n \
            --arg name "${TLS_RULE_NAME}" \
            --arg connector_id "${connector_id}" '{
            name: $name,
            rule_type_id: "xpack.uptime.alerts.tlsCertificate",
            consumer: "uptime",
            schedule: { interval: "1h" },
            tags: ["liveness", "phase2", "tls"],
            params: {},
            actions: [{
                id: $connector_id,
                group: "xpack.uptime.alerts.actionGroups.tlsCertificate",
                params: {
                    level: "warn",
                    message: "TLS cert near expiry: {{context.commonName}} on {{context.summary}}"
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
        echo "ERROR: tls rule create failed: ${response}" >&2
        exit 1
    fi
    echo "  created: ${new_id}"
fi

echo
echo "All Uptime alerting resources present. Alerts will surface in"
echo "Kibana logs (journalctl -u kibana | grep -E 'Uptime|TLS')."
