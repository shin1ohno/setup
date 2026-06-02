#!/bin/bash
# generate-home-local.sh — render unbound home.local local-data from SSM.
#
# Fetches /host-registry/home-local-records (published by home-monitor Terraform
# from local.private_dns_forward) and renders one `local-zone ... static` +
# one `local-data ... IN A <ip>` per hostname/IP, splicing them into the
# @@HOME_LOCAL_LOCAL_DATA@@ marker in TEMPLATE to produce OUTPUT.
#
# This lets unbound (CT118/.61) serve home.local LOCALLY instead of forwarding
# every query to the VPC Route53 resolver (10.33.128.2) over the Tailscale subnet
# route — a wedge-prone path (forwarder RTO maxes at 120000ms after a transient
# VPC outage and SERVFAILs home.local until restarted).
#
# Graceful degradation: if the SSM fetch fails or returns nothing (missing creds,
# param absent), the marker renders EMPTY and home.local falls back to the
# forward-zone (Route53) — i.e. the pre-local-data behaviour, never an invalid
# config. A WARN is emitted so the operator notices the missing local-data.
#
# Inputs (env): AWS_PROFILE, AWS_REGION, SSM_PARAM (default
# /host-registry/home-local-records), TEMPLATE, OUTPUT, TTL (default 3600).
set -uo pipefail

AWS_PROFILE="${AWS_PROFILE:?AWS_PROFILE required}"
AWS_REGION="${AWS_REGION:?AWS_REGION required}"
SSM_PARAM="${SSM_PARAM:-/host-registry/home-local-records}"
TEMPLATE="${TEMPLATE:?TEMPLATE required}"
OUTPUT="${OUTPUT:?OUTPUT required}"
TTL="${TTL:-3600}"
MARKER="@@HOME_LOCAL_LOCAL_DATA@@"

gen_file="$(mktemp)"
out_tmp="$(mktemp "${OUTPUT}.XXXXXX")"
trap 'rm -f "${gen_file}" "${out_tmp}"' EXIT

records_json="$(
    aws ssm get-parameter \
        --name "${SSM_PARAM}" \
        --query "Parameter.Value" \
        --output text \
        --profile "${AWS_PROFILE}" \
        --region "${AWS_REGION}" 2>/dev/null
)" || records_json=""

if [[ -n "${records_json}" ]] && echo "${records_json}" | jq -e 'type == "object"' >/dev/null 2>&1; then
    # One local-zone (static, terminal) per hostname + one local-data A per IP.
    # Multiple IPs per name are all emitted (matches the Route53 multi-value
    # records; an improvement over the RTX block which kept only the first IP).
    echo "${records_json}" | jq -r --arg ttl "${TTL}" '
        to_entries[]
        | select(.value | length > 0)
        | .key as $h
        | ("    local-zone: \"" + $h + ".home.local.\" static"),
          (.value[] | "    local-data: \"" + $h + ".home.local. " + $ttl + " IN A " + . + "\"")
    ' >"${gen_file}"
    zones="$(grep -c 'local-zone:' "${gen_file}" 2>/dev/null || echo 0)"
    echo "generate-home-local: rendered ${zones} home.local names from ${SSM_PARAM}" >&2
else
    : >"${gen_file}"
    echo "WARN generate-home-local: SSM fetch of ${SSM_PARAM} failed or empty" \
         "(profile=${AWS_PROFILE}, region=${AWS_REGION}) — home.local will fall back" \
         "to forward-only (10.33.128.2). Seed ${AWS_PROFILE} creds on this host to" \
         "restore VPC-independent local resolution." >&2
fi

# Splice the generated block at the marker line (whole marker line is replaced).
awk -v gen_file="${gen_file}" -v marker="${MARKER}" '
    index($0, marker) > 0 {
        while ((getline line < gen_file) > 0) print line
        close(gen_file)
        next
    }
    { print }
' "${TEMPLATE}" >"${out_tmp}"

mv "${out_tmp}" "${OUTPUT}"
trap 'rm -f "${gen_file}"' EXIT
