#!/bin/bash
# es-cluster-health.sh — write the Elasticsearch cluster health color as a
# node_exporter textfile metric so Prometheus (already scraping node-es-*
# on :9100) can alert on a RED/YELLOW cluster.
#
# Reuses the existing node_exporter textfile-collector pattern (cf.
# drift-checker.prom / auto-mitamae.prom on the monitoring host) rather than
# deploying a separate elasticsearch_exporter — the es nodes already have the
# CA cert + es_monitor creds locally and are already scraped, so no new
# binary and no new Prometheus scrape job is needed.
#
# Runs on EACH es node via es-cluster-health.timer (every ~60s). The cluster
# status is cluster-wide, so all 3 nodes report the same value; alerts use
# max()/min() across nodes so they stay correct when a single node is down.
#
# Origin: the 2026-05 corrupt-shard RED cluster (a .ds-metrics-prometheus
# backing index) went undetected because ES cluster health was not scraped —
# it surfaced only indirectly as auto-mitamae es-* apply failures.
set -uo pipefail

ENV_FILE="${ENV_FILE:-/etc/elasticsearch/elasticsearch-secrets.env}"
CA_CERT="${CA_CERT:-/etc/elasticsearch/certs/ca.crt}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
OUT="${TEXTFILE_DIR}/es-cluster-health.prom"

# Load secrets the metacharacter-safe way (matches bootstrap-init.sh):
# passwords may contain shell metacharacters that `source` would mangle.
if [[ -f "${ENV_FILE}" ]]; then
  while IFS='=' read -r __k __v; do
    [[ "${__k}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${__k// }" ]] && continue
    eval "${__k}=\$__v"
  done < "${ENV_FILE}"
fi

host="${TRANSPORT_HOST:-localhost}"
status="unknown"
if [[ -n "${MONITOR_PASSWORD:-}" ]]; then
  resp=$(curl -sS --max-time 10 --cacert "${CA_CERT}" \
    -u "es_monitor:${MONITOR_PASSWORD}" \
    "https://${host}:9200/_cluster/health" 2>/dev/null || true)
  parsed=$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' <<<"${resp}")
  [[ -n "${parsed}" ]] && status="${parsed}"
fi

now=$(date +%s)

# SLM last-successful-snapshot age. es_monitor holds read_slm via the
# cluster_health_monitor role. A stalled backup is otherwise invisible — the
# 2026-05 incident had ~11 of 20 days with no successful snapshot and zero
# operator signal. slm_age = -1 means SLM is unreadable or never succeeded
# (the ESSnapshotStale alert treats -1 as stale). last_success is a flat JSON
# object (no nested braces), so the [^}]* extraction is safe. The completion
# timestamp field in last_success is "time" (epoch ms) — NOT "time_in_millis";
# "start_time" is a separate field and the "time":<n> pattern does not match
# inside "start_time": (the char before t there is '_', not '"').
slm_age="-1"
if [[ -n "${MONITOR_PASSWORD:-}" ]]; then
  slm=$(curl -sS --max-time 10 --cacert "${CA_CERT}" \
    -u "es_monitor:${MONITOR_PASSWORD}" \
    "https://${host}:9200/_slm/policy/daily-snapshot" 2>/dev/null || true)
  ts=$(grep -oE '"last_success":\{[^}]*"time":[0-9]+' <<<"${slm}" | grep -oE '[0-9]+$')
  [[ -n "${ts}" ]] && slm_age=$(( now - ts / 1000 ))
fi

mkdir -p "${TEXTFILE_DIR}"
tmp=$(mktemp "${OUT}.XXXXXX")
trap 'rm -f "${tmp}"' EXIT
{
  echo "# HELP elasticsearch_cluster_status ES cluster health color (1 = current color)"
  echo "# TYPE elasticsearch_cluster_status gauge"
  for c in green yellow red unknown; do
    v=0
    [[ "${status}" == "${c}" ]] && v=1
    echo "elasticsearch_cluster_status{color=\"${c}\"} ${v}"
  done
  echo "# HELP elasticsearch_cluster_health_scrape_timestamp_seconds Unix time of last health probe"
  echo "# TYPE elasticsearch_cluster_health_scrape_timestamp_seconds gauge"
  echo "elasticsearch_cluster_health_scrape_timestamp_seconds ${now}"
  echo "# HELP elasticsearch_slm_last_success_age_seconds Seconds since the last successful SLM snapshot (-1 = unknown/never)"
  echo "# TYPE elasticsearch_slm_last_success_age_seconds gauge"
  echo "elasticsearch_slm_last_success_age_seconds ${slm_age}"
} > "${tmp}"
mv "${tmp}" "${OUT}"
trap - EXIT
chmod 0644 "${OUT}"
