#!/bin/bash
# generate-home-local.sh — render unbound home.local local-data from SSM.
#
# Fetches /host-registry/home-local-records and
# /host-registry/home-local-records-v6 (both published by home-monitor
# Terraform, from local.private_dns_forward and local.private_dns_forward_v6)
# and renders one `local-zone ... static` per hostname plus one
# `local-data ... IN A|AAAA <addr>` per address, splicing them into the
# @@HOME_LOCAL_LOCAL_DATA@@ marker in TEMPLATE to produce OUTPUT.
#
# The AAAA side carries ULA addresses only. The LAN's globally-routable prefix
# is DHCPv6-PD delegated and rotates, so a published GUA would point at an
# address the host no longer holds.
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
# /host-registry/home-local-records), SSM_PARAM_V6 (default
# /host-registry/home-local-records-v6), TEMPLATE, OUTPUT, TTL (default 3600).
set -uo pipefail

AWS_PROFILE="${AWS_PROFILE:?AWS_PROFILE required}"
AWS_REGION="${AWS_REGION:?AWS_REGION required}"
SSM_PARAM="${SSM_PARAM:-/host-registry/home-local-records}"
SSM_PARAM_V6="${SSM_PARAM_V6:-/host-registry/home-local-records-v6}"
TEMPLATE="${TEMPLATE:?TEMPLATE required}"
OUTPUT="${OUTPUT:?OUTPUT required}"
TTL="${TTL:-3600}"
MARKER="@@HOME_LOCAL_LOCAL_DATA@@"

gen_file="$(mktemp)"
out_tmp="$(mktemp "${OUTPUT}.XXXXXX")"
trap 'rm -f "${gen_file}" "${out_tmp}"' EXIT

# Fetch one SSM parameter and echo it only if it parses as a JSON object.
# Anything else — missing param, no creds, garbage value — echoes nothing, so
# the caller sees an empty map and degrades instead of rendering junk.
fetch_map() {
    local name="$1" value
    value="$(
        aws ssm get-parameter \
            --name "${name}" \
            --query "Parameter.Value" \
            --output text \
            --profile "${AWS_PROFILE}" \
            --region "${AWS_REGION}" 2>/dev/null
    )" || value=""
    if [[ -n "${value}" ]] && echo "${value}" | jq -e 'type == "object"' >/dev/null 2>&1; then
        echo "${value}"
    fi
}

records_v4="$(fetch_map "${SSM_PARAM}")"
records_v6="$(fetch_map "${SSM_PARAM_V6}")"

if [[ -z "${records_v4}" ]]; then
    records_v4='{}'
    echo "WARN generate-home-local: SSM fetch of ${SSM_PARAM} failed or empty" \
         "(profile=${AWS_PROFILE}, region=${AWS_REGION}) — home.local A records will be missing and" \
         "those names fall back to forward-only (10.33.128.2). Seed ${AWS_PROFILE} creds on this" \
         "host to restore VPC-independent local resolution." >&2
fi

# v6 absence is a WARN, not an error: the AAAA parameter is published by a
# separate Terraform apply, so a host can legitimately be ahead of it. Names
# then answer NODATA for AAAA, which is what they did before v6 existed.
if [[ -z "${records_v6}" ]]; then
    records_v6='{}'
    echo "WARN generate-home-local: SSM fetch of ${SSM_PARAM_V6} failed or empty" \
         "— home.local will be served without AAAA records." >&2
fi

# One local-zone (static, terminal) per hostname, then every A and AAAA that
# name has. The zone line must appear exactly ONCE even for a name present in
# both maps, hence the union of keys rather than two independent passes — a
# duplicate local-zone for the same name is a config error.
#
# `static` makes the zone terminal: a name with an A but no AAAA answers NODATA
# for AAAA rather than falling through to the forward-zone. That is the correct
# answer and it keeps Apple clients (no derivable stable v6 address, so no AAAA
# published) from generating a Route53 round-trip per lookup.
jq -n -r --argjson v4 "${records_v4}" --argjson v6 "${records_v6}" --arg ttl "${TTL}" '
    (($v4 | keys) + ($v6 | keys) | unique)[] as $h
    | ((($v4[$h] // []) | map({t: "A", v: .}))
       + (($v6[$h] // []) | map({t: "AAAA", v: .}))) as $rrs
    | select($rrs | length > 0)
    | ("    local-zone: \"" + $h + ".home.local.\" static"),
      ($rrs[] | "    local-data: \"" + $h + ".home.local. " + $ttl + " IN " + .t + " " + .v + "\"")
' >"${gen_file}"

# `grep -c` already prints 0 and exits 1 when there is no match, so the
# `|| echo 0` idiom appends a SECOND zero and the count becomes "0\n0". Let the
# non-zero exit through instead — the value on stdout is correct either way.
zones="$(grep -c 'local-zone:' "${gen_file}" 2>/dev/null)" || true
quads="$(grep -c ' IN AAAA ' "${gen_file}" 2>/dev/null)" || true
echo "generate-home-local: rendered ${zones:-0} home.local names (${quads:-0} with AAAA)" >&2

# Splice the generated block at the marker line. Match ONLY a comment line that
# is exactly the marker (leading whitespace + "#" + marker), so prose elsewhere
# that happens to mention the marker token is NOT also replaced — otherwise the
# block would be spliced twice (once before `server:`, breaking the config).
awk -v gen_file="${gen_file}" -v marker="${MARKER}" '
    $0 ~ ("^[[:space:]]*#[[:space:]]*" marker "[[:space:]]*$") {
        while ((getline line < gen_file) > 0) print line
        close(gen_file)
        next
    }
    { print }
' "${TEMPLATE}" >"${out_tmp}"

# Never publish a render that unbound cannot parse. Without this the bad file
# reaches OUTPUT, the recipe's staged-validate catches it and aborts the apply,
# and the stale-but-valid OUTPUT from the previous run is gone — so the next
# apply has nothing good to fall back to. Failing here leaves OUTPUT untouched.
#
# checkconf accepts the fragment on its own (self-contained `server:` section).
#
# A missing binary is a hard failure, not a warn-and-continue: skipping the
# check and publishing anyway would overwrite the last good OUTPUT with an
# unvalidated render, which is precisely the case this block exists to prevent.
# The recipe installs unbound before it renders, so the only way to get here is
# that install having failed — and aborting is the right answer to that too.
#
# Explicit `if ! ...; then exit 1; fi` rather than relying on an abort: this
# script runs under `set -uo pipefail` with no `-e`, so a bare failing command
# would sail straight past.
CHECKCONF="${CHECKCONF:-/usr/sbin/unbound-checkconf}"
if [[ ! -x "${CHECKCONF}" ]]; then
    echo "ERROR generate-home-local: ${CHECKCONF} is not executable, so the" \
         "rendered config cannot be validated. Refusing to publish it over" \
         "${OUTPUT}. Is unbound installed?" >&2
    exit 1
fi

if ! "${CHECKCONF}" "${out_tmp}" >/dev/null 2>&1; then
    # Keep the rejected render for inspection. The EXIT trap deletes out_tmp,
    # so pointing an operator at that path would hand them a file that no
    # longer exists by the time they read the message.
    rejected="${OUTPUT}.rejected"
    cp -f "${out_tmp}" "${rejected}" 2>/dev/null || rejected="(could not be saved)"
    echo "ERROR generate-home-local: rendered config failed unbound-checkconf;" \
         "leaving ${OUTPUT} unchanged. Rejected render saved to ${rejected}." >&2
    "${CHECKCONF}" "${out_tmp}" >&2 || true
    exit 1
fi

# A previous run may have left a rejected render behind; this one succeeded, so
# drop it rather than leaving a stale file to mislead the next reader.
rm -f "${OUTPUT}.rejected"

mv "${out_tmp}" "${OUTPUT}"
trap 'rm -f "${gen_file}"' EXIT
