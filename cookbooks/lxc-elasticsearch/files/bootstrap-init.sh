#!/bin/bash
# Idempotent ES cluster bootstrap + drift detection.
#
# Runs on every cookbook converge after the elasticsearch container is
# healthy. Designed to be safe to re-run any number of times — every step
# is gated on the current cluster state.
#
# Bootstrap steps (executed in this strict order):
#   1. Wait for cluster to be at least YELLOW (single-node OK during
#      cluster formation; goes GREEN once 2+ peer nodes joined).
#   2. PUT ILM policy logs-rtx-7d.
#   3. PUT component templates (logs-rtx-mappings, logs-rtx-settings).
#   4. PUT index template logs-rtx (data_stream: {}, composed_of bind).
#   5. Create data stream logs-rtx-default (PUT _data_stream/, idempotent
#      404→create, 200→exists).
#   6. PUT roles (vector_writer / grafana_reader / rtx_analyst).
#   7. Drift-detection loop: for each application user, probe
#      _security/_authenticate; on 401, run elasticsearch-reset-password
#      with the SSM-fetched password to re-sync. Same protocol applies
#      to the kibana_system built-in (Adversarial #12 atomic 2-step:
#      ES-side reset must complete before Kibana cookbook reads the
#      same SSM password into kibana.yml).
#
# Idempotency strategy: each step runs through "PUT then check expected
# response" rather than "GET then maybe PUT". Elasticsearch PUT semantics
# on these endpoints are upsert (200 OK on first write, 200 OK on
# repeated writes) so PUT is the cheapest idempotent shape.
#
# Usage:
#   bootstrap-init.sh <cookbook_files_dir>
# where the files dir contains ilm-policy-rtx-7d.json,
# component-templates/*.json, index-template-rtx.json, bootstrap-roles.json
# and the .env-derived ELASTIC_PASSWORD / KIBANA_PASSWORD / ... in env.

set -euo pipefail

FILES_DIR="${1:?usage: $0 <files_dir>}"
ES_URL="${ES_URL:-http://localhost:9200}"

# .env load — required vars: ELASTIC_PASSWORD, KIBANA_PASSWORD,
# VECTOR_PASSWORD, GRAFANA_PASSWORD, ANALYST_PASSWORD, MONITOR_PASSWORD.
# Parsed with explicit while-read + eval rather than `source` so that
# raw passwords with shell metacharacters (parens, brackets, ampersand,
# etc) survive intact. `.env` format matches docker-compose's env_file:
# KEY=VALUE with no quoting, allowing the same file to be consumed by
# both bootstrap-init.sh (here) and `docker compose`.
if [[ -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
  while IFS='=' read -r __k __v; do
    [[ "${__k}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${__k// }" ]] && continue
    # eval "key=\$__v" literal-assigns __v's content to <key> without
    # re-parsing metacharacters in __v.
    eval "${__k}=\$__v"
    export "${__k}"
  done < "${ENV_FILE}"
fi

: "${ELASTIC_PASSWORD:?ELASTIC_PASSWORD must be set}"
: "${KIBANA_PASSWORD:?KIBANA_PASSWORD must be set}"
: "${VECTOR_PASSWORD:?VECTOR_PASSWORD must be set}"
: "${GRAFANA_PASSWORD:?GRAFANA_PASSWORD must be set}"
: "${ANALYST_PASSWORD:?ANALYST_PASSWORD must be set}"
: "${MONITOR_PASSWORD:?MONITOR_PASSWORD must be set}"
: "${ELASTIC_AGENT_PASSWORD:?ELASTIC_AGENT_PASSWORD must be set}"

CURL_AUTH=(-u "elastic:${ELASTIC_PASSWORD}")
CURL_OPTS=(-sS --max-time 30)

# Phase 7-tls: ES is HTTPS. Trust the cluster's CA when ES_URL starts
# with https:// — orchestrator passes "ES_URL=https://<ip>:9200" to
# this script. CA is at /etc/elasticsearch/certs/ca.crt (Phase 3b
# transport CA reused for HTTP layer).
if [[ "${ES_URL}" == https://* ]]; then
  CURL_OPTS+=(--cacert /etc/elasticsearch/certs/ca.crt)
fi

es_curl() {
  curl "${CURL_OPTS[@]}" "${CURL_AUTH[@]}" "$@"
}

# --- Step 0: ensure local elastic password matches SSM -------------------
#
# Native install case (Phase 3b retro): when a fresh ES node joins an
# existing cluster (e.g. CT 112 native joining a docker-era cluster on
# CT 113/114), the local node's reserved-realm cache may not match the
# cluster security index immediately. The drift-detection loop below
# handles non-built-in users via the ES API, but the `elastic` superuser
# is required to authenticate that API in the first place.
#
# elasticsearch-reset-password uses local TLS bypass (operates directly
# on the node's security index without needing API auth) — safe to run
# unconditionally on cookbook-managed mitamae apply. If the password is
# already in sync, the reset is a no-op; if not, this fixes the auth
# loop before the API-based steps below try to use it.
ensure_local_elastic_password() {
  # Skip if API auth already works (steady-state re-apply).
  local code
  code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    -u "elastic:${ELASTIC_PASSWORD}" \
    "${ES_URL}/_security/_authenticate" 2>/dev/null || echo "000")
  if [[ "${code}" == "200" ]]; then
    echo "[bootstrap] local elastic password already in sync"
    return 0
  fi

  # Reset via local TLS bypass — works even when API auth is broken.
  local reset_bin="/usr/share/elasticsearch/bin/elasticsearch-reset-password"
  if [[ ! -x "${reset_bin}" ]]; then
    echo "[bootstrap] WARN: ${reset_bin} not present (not a native install?); skipping" >&2
    return 0
  fi

  echo "[bootstrap] resetting local elastic password (API auth returned ${code})"
  "${reset_bin}" -u elastic -i --batch <<EOF
${ELASTIC_PASSWORD}
${ELASTIC_PASSWORD}
EOF
}

# --- Step 1: wait for cluster YELLOW (or better) -------------------------

wait_cluster_ready() {
  local i
  for i in $(seq 1 60); do
    local status
    status=$(es_curl "${ES_URL}/_cluster/health" \
      | sed -n 's/.*"status":"\([^"]*\)".*/\1/p' || true)
    case "${status}" in
      yellow|green)
        echo "[bootstrap] cluster status=${status} (after ${i} probes)"
        return 0
        ;;
    esac
    sleep 5
  done
  echo "[bootstrap] cluster not ready after 5 minutes — aborting" >&2
  return 1
}

# --- Step 2: ILM policy --------------------------------------------------

put_ilm_policy() {
  local body
  body=$(cat "${FILES_DIR}/ilm-policy-rtx-7d.json")
  es_curl -H 'Content-Type: application/json' \
    -X PUT "${ES_URL}/_ilm/policy/logs-rtx-7d" \
    -d "${body}" \
    | grep -q '"acknowledged":true' || {
      echo "[bootstrap] ILM policy PUT failed" >&2
      return 1
    }
  echo "[bootstrap] ILM policy logs-rtx-7d ensured"
}

# --- Step 3: component templates ----------------------------------------

put_component_template() {
  local name="$1"
  local file="$2"
  local body
  body=$(cat "${file}")
  es_curl -H 'Content-Type: application/json' \
    -X PUT "${ES_URL}/_component_template/${name}" \
    -d "${body}" \
    | grep -q '"acknowledged":true' || {
      echo "[bootstrap] component_template ${name} PUT failed" >&2
      return 1
    }
  echo "[bootstrap] component_template ${name} ensured"
}

# --- Step 4: index template ----------------------------------------------

put_index_template() {
  local body
  body=$(cat "${FILES_DIR}/index-template-rtx.json")
  es_curl -H 'Content-Type: application/json' \
    -X PUT "${ES_URL}/_index_template/logs-rtx" \
    -d "${body}" \
    | grep -q '"acknowledged":true' || {
      echo "[bootstrap] index_template PUT failed" >&2
      return 1
    }
  echo "[bootstrap] index_template logs-rtx ensured"
}

# --- Step 5: data stream -------------------------------------------------
#
# Adversarial #8: data stream creation must happen AFTER the index template
# is registered, otherwise the initial backing index is created from
# defaults and ignores the ILM policy. Conversely, repeated PUT on a
# data stream that already exists returns 400 — so check existence first.

ensure_data_stream() {
  local code
  code=$(es_curl -o /dev/null -w '%{http_code}' "${ES_URL}/_data_stream/logs-rtx-default")
  case "${code}" in
    200)
      echo "[bootstrap] data stream logs-rtx-default already exists"
      ;;
    404)
      es_curl -X PUT "${ES_URL}/_data_stream/logs-rtx-default" \
        | grep -q '"acknowledged":true' || {
          echo "[bootstrap] data stream PUT failed" >&2
          return 1
        }
      echo "[bootstrap] data stream logs-rtx-default created"
      ;;
    *)
      echo "[bootstrap] unexpected HTTP ${code} probing data stream" >&2
      return 1
      ;;
  esac
}

# --- Step 6: roles -------------------------------------------------------

put_role() {
  local role="$1"
  local body
  # Extract a single role definition from bootstrap-roles.json. Avoids
  # depending on jq (not always pre-installed). The python alternative
  # would parse cleanly but adds another runtime dep.
  body=$(python3 -c "
import json, sys
with open('${FILES_DIR}/bootstrap-roles.json') as f:
    data = json.load(f)
print(json.dumps(data['${role}']))
")
  es_curl -H 'Content-Type: application/json' \
    -X PUT "${ES_URL}/_security/role/${role}" \
    -d "${body}" \
    | grep -q '"created":\(true\|false\)' || {
      echo "[bootstrap] role ${role} PUT failed" >&2
      return 1
    }
  echo "[bootstrap] role ${role} ensured"
}

# --- Step 7: user drift detection + reset --------------------------------
#
# Adversarial #14: Terraform regenerates passwords on demand; cookbook
# must re-sync ES users to match. Probe with each SSM password — if it
# fails, reset.
#
# Adversarial #12: kibana_system is a built-in user; password is reset
# via the same /_security/user/kibana_system/_password endpoint (no role
# create needed).

probe_user_password() {
  local user="$1"
  local password="$2"
  local code
  code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
    -u "${user}:${password}" \
    "${ES_URL}/_security/_authenticate")
  test "${code}" = "200"
}

# Build payload for users that might already exist (PUT user is upsert).
put_or_reset_user() {
  local user="$1"
  local password="$2"
  local roles_json="$3"

  # First try the auth probe — if it succeeds the password is already in
  # sync, no further action needed.
  if probe_user_password "${user}" "${password}"; then
    echo "[bootstrap] user ${user} password already in sync"
    return 0
  fi

  # Use _security/user upsert; works for both create and password rotate
  # for non-builtin users. The body carries the new password and the
  # current role assignment.
  local body
  body=$(python3 -c "
import json, sys
print(json.dumps({
    'password': '${password}',
    'roles': ${roles_json}
}))
")
  es_curl -H 'Content-Type: application/json' \
    -X POST "${ES_URL}/_security/user/${user}" \
    -d "${body}" \
    > /dev/null
  echo "[bootstrap] user ${user} password (re)set"
}

reset_kibana_system_password() {
  # Skip if already in sync.
  if probe_user_password "kibana_system" "${KIBANA_PASSWORD}"; then
    echo "[bootstrap] kibana_system password already in sync"
    return 0
  fi
  # Built-in user — only password is settable, never roles.
  es_curl -H 'Content-Type: application/json' \
    -X POST "${ES_URL}/_security/user/kibana_system/_password" \
    -d "{\"password\":\"${KIBANA_PASSWORD}\"}" \
    > /dev/null
  echo "[bootstrap] kibana_system password reset"
}

# --- main ----------------------------------------------------------------

main() {
  wait_cluster_ready

  # Reset local elastic password if API auth is broken (native install
  # first-boot case where the local node's reserved-realm cache lags
  # the cluster security index). Must run before any es_curl call.
  ensure_local_elastic_password

  # Idempotent infrastructure setup. Order matters: ILM → component →
  # index template → data stream (Adversarial #8).
  put_ilm_policy
  put_component_template "logs-rtx-mappings" \
    "${FILES_DIR}/component-templates/logs-rtx-mappings.json"
  put_component_template "logs-rtx-settings" \
    "${FILES_DIR}/component-templates/logs-rtx-settings.json"
  put_index_template
  ensure_data_stream

  # Roles for application users.
  put_role "vector_writer"
  put_role "grafana_reader"
  put_role "rtx_analyst"
  put_role "elastic_agent_writer"

  # Drift detection — application users.
  put_or_reset_user "vector_writer"        "${VECTOR_PASSWORD}"        '["vector_writer"]'
  put_or_reset_user "grafana_reader"       "${GRAFANA_PASSWORD}"       '["grafana_reader"]'
  put_or_reset_user "rtx_analyst"          "${ANALYST_PASSWORD}"       '["rtx_analyst"]'
  put_or_reset_user "es_monitor"           "${MONITOR_PASSWORD}"       '["monitoring_user"]'
  put_or_reset_user "elastic_agent_writer" "${ELASTIC_AGENT_PASSWORD}" '["elastic_agent_writer"]'

  # Built-in kibana_system — only password can be set.
  reset_kibana_system_password

  echo "[bootstrap] complete"
}

main "$@"
