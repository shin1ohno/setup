#!/bin/bash
# Wait for the local Elasticsearch node to confirm a fully-formed 3-node
# cluster (es-0, es-1, es-2 all listed by _cat/nodes) before signalling
# `active` to systemd via ExecStartPost.
#
# Stream E (Phase 3b retro) identified that the docker-era healthcheck
# wait_for_status=yellow returned 200 the moment the local node reached
# yellow — even when only 1 of 3 expected master-eligible peers had
# joined. This produced publication-ack races during master election
# loops because downstream consumers (orchestrator, Kibana) treated the
# unit as `active` while the cluster was still forming.
#
# Strategy: poll the local HTTP endpoint with the elastic superuser and
# count distinct node names matching `^es-[0-2]$`. Exit 0 once the count
# reaches >=3, exit 1 on timeout. Designed to be invoked from systemd
# ExecStartPost= — the unit's TimeoutStartSec= MUST be longer than this
# script's WAIT_TIMEOUT (override sets TimeoutStartSec=600s, this script
# defaults to 300s).
#
# Graceful failure: if peers are also down (e.g. fleet-wide power cycle),
# the timeout fires and systemd marks the unit as failed start. The
# operator should then start peers in parallel; subsequent `systemctl
# restart elasticsearch` will succeed once 2 peers reach API-up.
#
# Inputs from /etc/elasticsearch/elasticsearch-secrets.env:
#   ELASTIC_PASSWORD  — elastic superuser password (for HTTP basic auth)
#   TRANSPORT_HOST    — node's bind IP (e.g. 192.168.1.77)
#
# The env file is owned root:elasticsearch mode 0640. systemd's
# EnvironmentFile= already reads it for the main ES process; this
# ExecStartPost script re-sources it explicitly because ExecStartPost
# inherits the unit's environment, so the same values are available
# here without re-reading the file. We still source defensively for
# clarity + to support manual invocation during debugging.

set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/elasticsearch/elasticsearch-secrets.env}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"  # seconds — keep < TimeoutStartSec
POLL_INTERVAL="${POLL_INTERVAL:-5}"
EXPECTED_NODES_REGEX='^es-[0-2]$'
EXPECTED_COUNT="${EXPECTED_COUNT:-3}"

if [[ -r "${ENV_FILE}" ]]; then
  # Bare KEY=VALUE pairs without shell expansion — same parser shape as
  # bootstrap-init.sh so metacharacter-bearing passwords survive intact.
  while IFS='=' read -r __k __v; do
    [[ "${__k}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${__k// }" ]] && continue
    eval "${__k}=\$__v"
    export "${__k}"
  done < "${ENV_FILE}"
fi

: "${ELASTIC_PASSWORD:?ELASTIC_PASSWORD must be set (env file readable?)}"
: "${TRANSPORT_HOST:?TRANSPORT_HOST must be set (env file readable?)}"

# Phase 7-tls: probe via HTTPS when http.ssl is enabled in elasticsearch.yml.
# Trust the cluster's CA (Phase 3b transport CA reused for HTTP layer).
ES_CONFIG="${ES_CONFIG:-/etc/elasticsearch/elasticsearch.yml}"
CA_CERT="${CA_CERT:-/etc/elasticsearch/certs/ca.crt}"
CURL_TLS=()
if grep -qE '^xpack\.security\.http\.ssl\.enabled:\s*true' "${ES_CONFIG}" 2>/dev/null; then
  ES_URL="https://${TRANSPORT_HOST}:9200"
  if [[ -f "${CA_CERT}" ]]; then
    CURL_TLS=(--cacert "${CA_CERT}")
  fi
else
  ES_URL="http://${TRANSPORT_HOST}:9200"
fi
deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
attempt=0

while :; do
  attempt=$((attempt + 1))
  now=$(date +%s)
  if (( now >= deadline )); then
    echo "[wait-cluster-ready] timeout after ${WAIT_TIMEOUT}s — cluster did not reach ${EXPECTED_COUNT} nodes" >&2
    # Emit the last observed state for postmortem clarity.
    curl -sS "${CURL_TLS[@]}" --max-time 5 -u "elastic:${ELASTIC_PASSWORD}" \
      "${ES_URL}/_cat/nodes?h=name" 2>&1 | sed 's|^|[wait-cluster-ready] last _cat/nodes: |' >&2 || true
    exit 1
  fi

  # -sf: silent + fail-on-non-2xx so the pipe receives empty output
  # rather than HTML / error JSON when the node isn't HTTP-ready yet.
  output=$(curl -sf "${CURL_TLS[@]}" --max-time 5 -u "elastic:${ELASTIC_PASSWORD}" \
    "${ES_URL}/_cat/nodes?h=name" 2>/dev/null || true)

  count=$(printf '%s\n' "${output}" | grep -cE "${EXPECTED_NODES_REGEX}" || true)

  if (( count >= EXPECTED_COUNT )); then
    echo "[wait-cluster-ready] cluster has ${count} nodes (>=${EXPECTED_COUNT}) after ${attempt} probes"
    exit 0
  fi

  # Progress emission every 6 attempts (~30s at default interval) so the
  # journal stays informative without flooding.
  if (( attempt % 6 == 1 )); then
    echo "[wait-cluster-ready] attempt ${attempt}: ${count}/${EXPECTED_COUNT} nodes visible (deadline in $((deadline - now))s)"
  fi

  sleep "${POLL_INTERVAL}"
done
