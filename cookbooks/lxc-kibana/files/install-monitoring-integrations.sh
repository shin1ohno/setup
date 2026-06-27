#!/usr/bin/env bash
#
# Install the Elasticsearch + Kibana integration packages (EPM) into Kibana.
#
# WHY: Stack Monitoring data is collected by a standalone Elastic Agent
# (elasticsearch/metrics + kibana/metrics inputs). The agent writes data but
# does NOT install the integration package assets. Without the package, the
# metrics-{elasticsearch,kibana}.stack_monitoring.* data streams are created
# from the generic `metrics` index template, which LACKS the monitoring-UI
# field aliases (timestamp, cluster_uuid, source_node). Kibana's Stack
# Monitoring cluster/node queries filter on those aliases, so the cluster is
# "not found" and every ES node shows Offline — even though node_stats data
# is present and correct.
#
# Installing the packages creates the proper index templates + component
# templates (with the aliases). New backing indices then carry the aliases.
# On an EXISTING cluster whose data streams predate the install, roll them
# over so the new write index adopts the integration template (this script
# does that automatically when the alias is missing).
#
# Idempotent: re-installing an already-installed package is a no-op; rollover
# only fires when the alias is absent.
#
# Env (required):
#   KIBANA_USER, KIBANA_PASSWORD  — elastic superuser (EPM install needs it)
# Env (optional):
#   KIBANA_URL  (default http://localhost:5601)
#   ES_URL      (default https://localhost:9200) — for the rollover check
#   ES_CA       (default /etc/kibana/certs/ca.crt)

set -euo pipefail

KIBANA_URL="${KIBANA_URL:-http://localhost:5601}"
KIBANA_USER="${KIBANA_USER:?KIBANA_USER must be set}"
KIBANA_PASSWORD="${KIBANA_PASSWORD:?KIBANA_PASSWORD must be set}"
ES_URL="${ES_URL:-https://localhost:9200}"
ES_CA="${ES_CA:-/etc/kibana/certs/ca.crt}"

kbn() {
  curl -sS -m 60 -u "${KIBANA_USER}:${KIBANA_PASSWORD}" \
    -H 'kbn-xsrf: true' -H 'Content-Type: application/json' "$@"
}
es() {
  local ca_opt=()
  [[ "${ES_URL}" == https://* && -f "${ES_CA}" ]] && ca_opt=(--cacert "${ES_CA}")
  curl -sS -m 30 "${ca_opt[@]}" -u "${KIBANA_USER}:${KIBANA_PASSWORD}" \
    -H 'Content-Type: application/json' "$@"
}

# Wait for Kibana to be available (EPM is a Kibana API).
for _ in $(seq 1 60); do
  if kbn -o /dev/null -w '%{http_code}' "${KIBANA_URL}/api/status" 2>/dev/null | grep -q '^200$'; then
    break
  fi
  sleep 5
done

install_package() {
  local pkg="$1" version="${2:-}" force="${3:-true}"
  local install_path="${KIBANA_URL}/api/fleet/epm/packages/${pkg}${version:+/${version}}"
  local status
  status=$(kbn "${KIBANA_URL}/api/fleet/epm/packages/${pkg}" 2>/dev/null \
    | sed -n 's/.*"status":"\([a-z_]*\)".*/\1/p' | head -1)
  if [[ "${status}" == "installed" ]]; then
    echo "[monitoring-integrations] ${pkg} already installed"
    return 0
  fi
  echo "[monitoring-integrations] installing ${pkg}${version:+ ${version}} (force=${force}) ..."
  kbn -X POST "${install_path}" -d "{\"force\":${force}}" \
    | grep -q '"items"' || {
      echo "[monitoring-integrations] ${pkg} install FAILED" >&2
      return 1
    }
  echo "[monitoring-integrations] ${pkg} installed"
}

install_package "elasticsearch"
install_package "kibana"
# AWS integration (billing data stream). Version-pinned + signature
# verification kept (force=false — NOT force:true, which would bypass package
# verification). Installs the metrics-aws.billing index template + ingest
# pipeline + the "[Metricbeat AWS] Billing Overview" dashboard that the CT 111
# standalone aws/billing input (cookbooks/elastic-agent) feeds.
install_package "aws" "6.20.2" "false"

# On an existing cluster, data streams created before the package install use
# the generic `metrics` template and lack the `timestamp` alias. Roll them
# over so the new write index adopts the integration template. Fresh installs
# (package present before any data) skip this — the alias is already there.
for ds in $(es "${ES_URL}/_data_stream/metrics-elasticsearch.stack_monitoring.*,metrics-kibana.stack_monitoring.*?filter_path=data_streams.name" 2>/dev/null \
  | tr ',' '\n' | sed -n 's/.*"name":"\([^"]*\)".*/\1/p'); do
  has_alias=$(es -o /dev/null -w '%{http_code}' \
    "${ES_URL}/${ds}/_mapping/field/timestamp" 2>/dev/null)
  # _mapping/field returns 200 with an empty body when the field is absent;
  # check the body for the field name instead.
  if ! es "${ES_URL}/${ds}/_mapping/field/timestamp" 2>/dev/null | grep -q '"timestamp"'; then
    echo "[monitoring-integrations] rolling over ${ds} (missing timestamp alias)"
    es -X POST "${ES_URL}/${ds}/_rollover" >/dev/null 2>&1 || true
  fi
done

echo "[monitoring-integrations] done"
