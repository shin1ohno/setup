#!/usr/bin/env bash
# Idempotent Kibana network-fault alerting setup (RTX routers + WLX access points).
#
# Reads expected-network-signals.json and creates one `.es-query` rule per
# entry in `signals[]`, named "Net: <title>". Detection is entirely declarative:
# the JSON owns the index, the DSL query, the comparator/threshold and the
# lookback window; this script only reconciles Kibana against it.
#
# Why Kibana rules and not a new detector daemon: the self-heal loop already
# turns an active Kibana alert into a GitHub issue and closes it when the alert
# clears (CT111 self-heal-observer -> ES self-heal-state -> self-heal-create ->
# shin1ohno/setup). Emitting rules means the whole notify/dedup/close path is
# reused unchanged, detection stays deterministic, and no LLM runs on a timer.
#
# The rule NAME becomes the GitHub issue title, because the observer builds its
# dedup_key as "<rule.name> :: <instance.id>" and self-heal-create titles the
# issue "[self-heal] <dedup_key>". Put the diagnosis in the name.
#
# Idempotency (mirrors setup-process-alerts.sh):
#   - rules are keyed by their deterministic name
#   - every rule carries a `cfg:<8 hex>` tag = hash of the signal's effective
#     params; if the JSON changes ANY param the hash moves and the rule is
#     UPDATED in place (setup-process-alerts.sh only tracks the window, which
#     silently strands a changed query on the old rule)
#   - rules tagged `netlog` whose name is no longer expected are PRUNED, so
#     renaming a signal retires its old rule instead of orphaning it as a
#     permanent false positive
#
# Action: Server Log connector (synthetics-server-log, created by
# setup-alerting.sh — run that first).
#
# Environment:
#   KIBANA_HOST       — Kibana base URL (default: http://localhost:5601)
#   KIBANA_USER       — Kibana basic-auth username (required)
#   KIBANA_PASSWORD   — Kibana basic-auth password (required)
#   NETALERT_DRY_RUN  — 1 = print what would change, touch nothing
#
# Usage (post-deploy from inside CT 115, AFTER setup-alerting.sh):
#   KIBANA_USER=elastic KIBANA_PASSWORD=... ./setup-network-alerts.sh
#
# Exit codes:
#   0 success   1 connector not found   2 json unreadable   3 a rule op failed

set -euo pipefail

KIBANA_HOST="${KIBANA_HOST:-http://localhost:5601}"
KIBANA_USER="${KIBANA_USER:?KIBANA_USER must be set}"
KIBANA_PASSWORD="${KIBANA_PASSWORD:?KIBANA_PASSWORD must be set}"
DRY_RUN="${NETALERT_DRY_RUN:-0}"

CONNECTOR_NAME="synthetics-server-log"
RULE_NAME_PREFIX="Net"
RULE_TAG="netlog"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIGNALS_JSON="${SCRIPT_DIR}/expected-network-signals.json"

if [[ ! -r "${SIGNALS_JSON}" ]]; then
    echo "ERROR: cannot read ${SIGNALS_JSON}" >&2
    exit 2
fi

if ! jq -e '.signals | type == "array" and length > 0' "${SIGNALS_JSON}" >/dev/null 2>&1; then
    echo "ERROR: ${SIGNALS_JSON} has no non-empty .signals array" >&2
    exit 2
fi

curl_kib() {
    curl -sS --max-time 30 \
        -u "${KIBANA_USER}:${KIBANA_PASSWORD}" \
        -H "kbn-xsrf: true" \
        -H "content-type: application/json" \
        "$@"
}

# Effective signal = the entry with _defaults filled in. Single source of the
# values used for both the rule body and the drift hash, so they cannot diverge.
effective_signal() {
    jq -c --argjson i "$1" '
        (._defaults // {}) as $d
        | .signals[$i]
        | {
            key,
            title,
            index,
            query,
            comparator:  (.comparator // ">"),
            threshold:   (.threshold  // 0),
            window:      (.window_minutes      // $d.window_minutes      // 15),
            interval:    (.interval            // $d.interval            // "1m"),
            exclude_prev:(if .exclude_previous_hits == null
                          then ($d.exclude_previous_hits // true)
                          else .exclude_previous_hits end),
            message:     (.message // "")
          }
    ' "${SIGNALS_JSON}"
}

# Drift hash over every param that shapes the rule. Any JSON edit moves it.
cfg_hash() {
    printf '%s' "$1" | jq -cS 'del(.message)' | sha1sum | cut -c1-8
}

# mode=create adds the immutable rule_type_id/consumer (POST); mode=update
# omits them (PUT /api/alerting/rule/<id>).
rule_body() {
    local sig="$1" mode="$2" cfg="$3"
    jq -n \
        --argjson s "${sig}" \
        --arg connector_id "${connector_id}" \
        --arg prefix "${RULE_NAME_PREFIX}" \
        --arg tag "${RULE_TAG}" \
        --arg cfg "cfg:${cfg}" \
        --arg mode "${mode}" '
        ($s.message | gsub("\\{\\{window\\}\\}"; ($s.window | tostring))) as $msg
        | {
            name: "\($prefix): \($s.title)",
            schedule: { interval: $s.interval },
            tags: [$tag, $cfg, $s.key],
            params: {
                searchType: "esQuery",
                timeField: "@timestamp",
                timeWindowSize: $s.window,
                timeWindowUnit: "m",
                threshold: [$s.threshold],
                thresholdComparator: $s.comparator,
                size: 100,
                index: $s.index,
                esQuery: ({ query: $s.query } | tojson),
                aggType: "count",
                groupBy: "all",
                excludeHitsFromPreviousRun: $s.exclude_prev
            },
            actions: [{
                id: $connector_id,
                group: "query matched",
                params: { level: "warn", message: $msg },
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
[[ "${DRY_RUN}" == "1" ]] && echo "DRY RUN — no rule will be created, updated or deleted"
echo

signal_count="$(jq -r '.signals | length' "${SIGNALS_JSON}")"

failures=0
created=0
updated=0
existing=0
expected_names=""

for (( i = 0; i < signal_count; i++ )); do
    sig="$(effective_signal "${i}")"
    title="$(jq -r '.title' <<< "${sig}")"
    rule_name="${RULE_NAME_PREFIX}: ${title}"
    cfg="$(cfg_hash "${sig}")"
    expected_names="${expected_names}${rule_name}"$'\n'

    echo "  ${rule_name} (cfg=${cfg})..."

    encoded_name="$(echo -n "\"${rule_name}\"" | jq -sRr @uri)"
    existing_id="$(curl_kib \
        "${KIBANA_HOST}/api/alerting/rules/_find?per_page=100&search_fields=name&search=${encoded_name}" \
        | jq -r --arg n "${rule_name}" \
            '.data[]? | select(.name == $n) | .id' | head -1)"

    if [[ -n "${existing_id}" ]]; then
        cur_cfg="$(curl_kib "${KIBANA_HOST}/api/alerting/rule/${existing_id}" \
            | jq -r '.tags[]? | select(startswith("cfg:")) | sub("^cfg:"; "")' | head -1)"
        if [[ "${cur_cfg}" == "${cfg}" ]]; then
            echo "    exists: ${existing_id}"
            existing=$(( existing + 1 ))
            continue
        fi
        if [[ "${DRY_RUN}" == "1" ]]; then
            echo "    would update cfg ${cur_cfg:-none}->${cfg}: ${existing_id}"
            updated=$(( updated + 1 ))
            continue
        fi
        response="$(curl_kib -X PUT "${KIBANA_HOST}/api/alerting/rule/${existing_id}" \
            -d "$(rule_body "${sig}" update "${cfg}")")"
        if [[ -n "$(jq -r '.id // empty' <<< "${response}")" ]]; then
            echo "    updated cfg ${cur_cfg:-none}->${cfg}: ${existing_id}"
            updated=$(( updated + 1 ))
        else
            echo "    ERROR: update failed: ${response}" >&2
            failures=$(( failures + 1 ))
        fi
        continue
    fi

    if [[ "${DRY_RUN}" == "1" ]]; then
        echo "    would create"
        created=$(( created + 1 ))
        continue
    fi

    response="$(curl_kib -X POST "${KIBANA_HOST}/api/alerting/rule" \
        -d "$(rule_body "${sig}" create "${cfg}")")"
    new_id="$(jq -r '.id // empty' <<< "${response}")"
    if [[ -z "${new_id}" ]]; then
        echo "    ERROR: create failed: ${response}" >&2
        failures=$(( failures + 1 ))
        continue
    fi
    echo "    created: ${new_id}"
    created=$(( created + 1 ))
done

# --------------------------------------------------------------------------
# Prune: delete `netlog` rules whose name is no longer in the JSON. Renaming a
# signal changes the rule NAME; without pruning the old-named rule lingers and
# fires forever. Scoped strictly to rules tagged `netlog`.
# --------------------------------------------------------------------------
expected_names="$(printf '%s' "${expected_names}" | sort -u)"

pruned=0
all_netlog="$(curl_kib "${KIBANA_HOST}/api/alerting/rules/_find?per_page=200" \
    | jq -r --arg tag "${RULE_TAG}" \
        '.data[]? | select(.tags | index($tag)) | "\(.id)\t\(.name)"')"

while IFS=$'\t' read -r rid rname; do
    [[ -z "${rid}" ]] && continue
    if ! grep -qxF "${rname}" <<< "${expected_names}"; then
        if [[ "${DRY_RUN}" == "1" ]]; then
            echo "  would prune stale rule: ${rname} (${rid})"
            pruned=$(( pruned + 1 ))
            continue
        fi
        echo "  pruning stale rule: ${rname} (${rid})"
        if curl_kib -X DELETE "${KIBANA_HOST}/api/alerting/rule/${rid}" >/dev/null; then
            pruned=$(( pruned + 1 ))
        else
            echo "    ERROR: prune delete failed for ${rid}" >&2
            failures=$(( failures + 1 ))
        fi
    fi
done <<< "${all_netlog}"

echo
echo "Network signal rules: created=${created} updated=${updated} existing=${existing} pruned=${pruned} failures=${failures}"

if [[ ${failures} -gt 0 ]]; then
    exit 3
fi
