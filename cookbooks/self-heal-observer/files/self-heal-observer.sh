#!/usr/bin/env bash
#
# self-heal-observer (Layer 1) — read-only ES alert reader + state writer.
# Polls the alerts-as-data indices Kibana writes, dedups against the
# self-heal-state index, and records NEW/RESOLVED transitions there.
# Notification + remediation are downstream loops on pro-dev (self-heal-create
# syncs this state to GitHub issues; self-heal-resolve fixes them) — this
# observer does NOT notify. Emits Prometheus textfile metrics for its own
# liveness. NEVER mutates fleet state. See
# ~/self-heal-observability-loop-design.md (Layer 1) and
# docs/self-heal-github-issues-plan.md.
#
# Invoked by /etc/cron.d/self-heal-observer as:
#   timeout 120 flock -n /var/lock/self-heal-observer.lock \
#     /usr/local/bin/self-heal-observer.sh --once
#
# Predicate is kibana.alert.status=="active" with NO @timestamp window:
# @timestamp is not refreshed while an alert stays active (a 21-day-active
# alert keeps its original @timestamp), so a recency window would drop real
# continuously-active problems. Dedup/transitions come from self-heal-state.

set -uo pipefail

ENV_FILE="/etc/self-heal/observer.env"
# shellcheck source=/dev/null
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

: "${SELF_HEAL_ES_HOSTS:=https://es-0.home.local:9200 https://es-1.home.local:9200 https://es-2.home.local:9200}"
: "${SELF_HEAL_ES_CA:=/etc/elastic-agent/certs/ca.crt}"
: "${SELF_HEAL_ELASTIC_PW_SSM:=/monitoring/elastic/elastic-password}"
: "${SELF_HEAL_AWS_PROFILE:=pve-bootstrap-ssm}"
: "${SELF_HEAL_AWS_REGION:=ap-northeast-1}"
: "${SELF_HEAL_STATE_INDEX:=self-heal-state}"
: "${SELF_HEAL_ALERT_INDICES:=.alerts-observability.uptime.alerts-default,.alerts-stack.alerts-default}"
: "${SELF_HEAL_TEXTFILE:=/var/lib/node_exporter/textfile/self-heal-observer.prom}"
: "${SELF_HEAL_DISABLED_SENTINEL:=/var/lib/self-heal/DISABLED}"
: "${SELF_HEAL_PW_CACHE:=/run/self-heal/elastic-pw.cache}"
: "${SELF_HEAL_PW_CACHE_TTL:=1800}"

log() { echo "[self-heal-observer] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }

# --- textfile (atomic) ------------------------------------------------------
# write_textfile <result: ok|error> <active_count>
write_textfile() {
  local result="$1" count="${2:-0}" ts tmp
  ts=$(date +%s)
  tmp="${SELF_HEAL_TEXTFILE}.tmp.$$"
  if {
    echo "# HELP self_heal_observer_last_run_timestamp_seconds Unix time the observer last completed a cycle."
    echo "# TYPE self_heal_observer_last_run_timestamp_seconds gauge"
    echo "self_heal_observer_last_run_timestamp_seconds ${ts}"
    echo "# HELP self_heal_observer_status Result of the last cycle (1 for the active result)."
    echo "# TYPE self_heal_observer_status gauge"
    if [ "$result" = "ok" ]; then
      echo 'self_heal_observer_status{result="ok"} 1'
      echo 'self_heal_observer_status{result="error"} 0'
    else
      echo 'self_heal_observer_status{result="ok"} 0'
      echo 'self_heal_observer_status{result="error"} 1'
    fi
    echo "# HELP self_heal_active_alerts Currently-active alerts observed in the alerts-as-data indices."
    echo "# TYPE self_heal_active_alerts gauge"
    echo "self_heal_active_alerts ${count}"
  } > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$SELF_HEAL_TEXTFILE" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

die_error() {
  log "ERROR: $*"
  write_textfile error 0
  exit 1
}

# --- elastic password (SSM with file cache) ---------------------------------
get_pw() {
  local age
  if [ -f "$SELF_HEAL_PW_CACHE" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$SELF_HEAL_PW_CACHE" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$SELF_HEAL_PW_CACHE_TTL" ]; then
      cat "$SELF_HEAL_PW_CACHE"
      return 0
    fi
  fi
  local pw
  pw=$(aws ssm get-parameter --name "$SELF_HEAL_ELASTIC_PW_SSM" --with-decryption \
        --query 'Parameter.Value' --output text \
        --profile "$SELF_HEAL_AWS_PROFILE" --region "$SELF_HEAL_AWS_REGION" 2>/dev/null)
  [ -n "$pw" ] || return 1
  mkdir -p "$(dirname "$SELF_HEAL_PW_CACHE")" 2>/dev/null
  ( umask 077; printf '%s' "$pw" > "$SELF_HEAL_PW_CACHE" )
  printf '%s' "$pw"
}

# --- ES request with es-0 -> es-1 -> es-2 fallback --------------------------
# es_req <method> <path> [data]  -> stdout body; returns non-zero if all hosts fail
es_req() {
  local method="$1" path="$2" data="${3:-}" host body
  for host in $SELF_HEAL_ES_HOSTS; do
    if [ -n "$data" ]; then
      body=$(curl -s -m 15 --cacert "$SELF_HEAL_ES_CA" -u "elastic:${ES_PW}" \
                  -H 'Content-Type: application/json' -X "$method" "${host}${path}" -d "$data" 2>/dev/null)
    else
      body=$(curl -s -m 15 --cacert "$SELF_HEAL_ES_CA" -u "elastic:${ES_PW}" \
                  -H 'Content-Type: application/json' -X "$method" "${host}${path}" 2>/dev/null)
    fi
    if [ -n "$body" ] && ! echo "$body" | grep -q '"error"[[:space:]]*:'; then
      printf '%s' "$body"
      return 0
    fi
  done
  return 1
}

sha1_id() { printf '%s' "$1" | sha1sum | cut -d' ' -f1; }

# --- main -------------------------------------------------------------------
main() {
  if [ -f "$SELF_HEAL_DISABLED_SENTINEL" ]; then
    log "DISABLED sentinel present (${SELF_HEAL_DISABLED_SENTINEL}) — skipping (no textfile update; SelfHealObserverStale is the intended signal)."
    exit 0
  fi

  ES_PW=$(get_pw) || die_error "could not obtain elastic password from SSM (${SELF_HEAL_ELASTIC_PW_SSM})"

  # Currently-active alerts across the two alerts-as-data indices.
  local active_query active_json active_tsv active_keys state_json state_keys
  active_query='{"size":500,"query":{"term":{"kibana.alert.status":"active"}},"_source":["kibana.alert.rule.name","kibana.alert.instance.id","kibana.alert.start","kibana.alert.reason"]}'
  active_json=$(es_req GET "/${SELF_HEAL_ALERT_INDICES}/_search" "$active_query") \
    || die_error "ES unreachable on all hosts (${SELF_HEAL_ES_HOSTS})"

  # TSV: dedup_key<TAB>start<TAB>reason(one-line). dedup_key = rule.name :: instance.id
  active_tsv=$(echo "$active_json" | jq -r '
    .hits.hits[]?._source
    | [ ((."kibana.alert.rule.name" // "?") + " :: " + (."kibana.alert.instance.id" // "-")),
        (."kibana.alert.start" // ""),
        ((."kibana.alert.reason" // "") | gsub("[\t\n]";" ")) ]
    | @tsv' 2>/dev/null)

  active_keys=$(printf '%s\n' "$active_tsv" | awk -F'\t' 'NF>0{print $1}' | sort -u)
  local active_count
  active_count=$(printf '%s\n' "$active_keys" | grep -c . || true)

  # Currently-open issues this observer is already tracking.
  state_json=$(es_req GET "/${SELF_HEAL_STATE_INDEX}/_search" \
    '{"size":1000,"query":{"term":{"status":"open"}},"_source":["dedup_key"]}') \
    || die_error "self-heal-state index unreachable (${SELF_HEAL_STATE_INDEX})"
  state_keys=$(echo "$state_json" | jq -r '.hits.hits[]?._source.dedup_key // empty' 2>/dev/null | sort -u)

  local state_open_count
  state_open_count=$(printf '%s\n' "$state_keys" | grep -c . || true)

  # Diff (comm needs sorted -u inputs, which both are).
  local new_keys resolved_keys
  new_keys=$(comm -23 <(printf '%s\n' "$active_keys" | grep -v '^$') <(printf '%s\n' "$state_keys" | grep -v '^$'))
  resolved_keys=$(comm -13 <(printf '%s\n' "$active_keys" | grep -v '^$') <(printf '%s\n' "$state_keys" | grep -v '^$'))

  local ts; ts=$(now_iso)

  # Upsert NEW open issues into self-heal-state. Notification is downstream
  # (self-heal-create on pro-dev reads this state and opens GitHub issues).
  while IFS= read -r dk; do
    [ -n "$dk" ] || continue
    local line reason start id idx source doc
    line=$(printf '%s\n' "$active_tsv" | awk -F'\t' -v k="$dk" '$1==k{print; exit}')
    start=$(printf '%s' "$line" | cut -f2)
    reason=$(printf '%s' "$line" | cut -f3)
    id=$(sha1_id "$dk")
    # source: which index family — uptime vs stack — by a cheap rule-name heuristic.
    case "$dk" in
      "Process down:"*) source="es-query" ;;
      *) source="uptime" ;;
    esac
    idx="$source"
    doc=$(jq -n --arg id "$id" --arg dk "$dk" --arg det "$ts" --arg fs "${start:-$ts}" \
                --arg ls "$ts" --arg src "$idx" --arg obs "$reason" '{
      id:$id, schema_version:1, detected_at:$det, source:$src, severity:"warning",
      signal:"kibana_alert_active", observed_value:$obs, probe_vantage:"ct111",
      first_seen:$fs, last_seen:$ls, occurrences:1, dedup_key:$dk,
      status:"open", auto_remediation_allowed:false }')
    es_req PUT "/${SELF_HEAL_STATE_INDEX}/_doc/${id}" "$doc" >/dev/null \
      || log "WARN: failed to upsert self-heal-state doc for: $dk"
  done <<< "$new_keys"

  # RESOLVED: mark resolved in self-heal-state (self-heal-create closes the
  # corresponding GitHub issue on its next cycle).
  while IFS= read -r dk; do
    [ -n "$dk" ] || continue
    local id
    id=$(sha1_id "$dk")
    es_req POST "/${SELF_HEAL_STATE_INDEX}/_update/${id}" \
      "$(jq -n --arg ls "$ts" '{doc:{status:"resolved", resolved_at:$ls, last_seen:$ls}}')" >/dev/null \
      || log "WARN: failed to mark resolved: $dk"
  done <<< "$resolved_keys"

  # CONTINUING: bump last_seen (no notify — dedup).
  while IFS= read -r dk; do
    [ -n "$dk" ] || continue
    local id
    id=$(sha1_id "$dk")
    es_req POST "/${SELF_HEAL_STATE_INDEX}/_update/${id}" \
      "$(jq -n --arg ls "$ts" '{doc:{last_seen:$ls}}')" >/dev/null 2>&1 || true
  done <<< "$(comm -12 <(printf '%s\n' "$active_keys" | grep -v '^$') <(printf '%s\n' "$state_keys" | grep -v '^$'))"

  log "cycle ok: active=${active_count} open_before=${state_open_count} new=$(printf '%s\n' "$new_keys" | grep -c . || true) resolved=$(printf '%s\n' "$resolved_keys" | grep -c . || true)"
  write_textfile ok "$active_count"
}

case "${1:-}" in
  --once) main ;;
  *) echo "usage: $0 --once" >&2; exit 2 ;;
esac
