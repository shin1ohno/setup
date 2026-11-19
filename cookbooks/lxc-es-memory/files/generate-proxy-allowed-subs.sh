#!/usr/bin/env bash
# generate-proxy-allowed-subs.sh <out-file> <floor-subs>
# generate-proxy-allowed-subs.sh --check <file>
#
# Writes one line, `ALLOWED_SUBS=<comma list>`, for memory-v2-proxy. The list is the
# FLOOR (the operator, passed by the cookbook) unioned with the SSM parameter
# /memory/proxy-allowed-subs (SecureString, comma-separated emails). The floor is
# always in the list, so a wrong or reduced parameter can never lock the operator
# out; an address removed from the parameter really drops out.
#
# Why a dedicated parameter: an authorization_code caller may read, write, forget
# and revise anything in the memory store, and claude.ai tokens carry no audience,
# so ALLOWED_SUBS is the only resource-level gate. It must not share a list with the
# OAuth consent app, whose list admits people to other gateway services too.
#
# Fail-safe contract: when the parameter cannot be read, or the value or the floor
# fails validation, this script writes NOTHING and exits 0 with a WARN on stderr. The
# cookbook then leaves the previous file in place; with no file at all, the unit's own
# inline ALLOWED_SUBS applies. It never prints an address.
#
# Why the strict validation: the output is a systemd EnvironmentFile, and a file line
# overrides every Environment= of the unit. A newline, quote or backslash could add or
# override another variable of the proxy (OIDC_JWKS_URL, MEMORY_AUDIENCES, ...), which
# would turn write access to the parameter into control of the proxy's authentication.
#
# --check <file>: exit 0 only if the file is exactly one line of
# `ALLOWED_SUBS=<valid email list>` (the cookbook runs it again before placing the
# file, so a file that did not come from this generator is not trusted).
#
# Env: AWS_PROFILE and AWS_REGION are required (the identity is never taken from the
#      ambient default). ALLOWED_SUBS_PARAM overrides the parameter name (tests only).
set -u
set -f
export LC_ALL=C

max_len=2048
max_entries=64

warn() { printf 'WARN generate-proxy-allowed-subs: %s\n' "$*" >&2; }

# normalize <comma list>: prints the list without empty elements and duplicates, in
# input order. Returns 1 (printing nothing) if ANY element is not a plain email.
normalize() {
  local s=$1 part list="" seen=","
  [[ $s != *$'\n'* && $s != *$'\r'* ]] || return 1
  (( ${#s} <= max_len )) || return 1
  [[ $s =~ ^[A-Za-z0-9._+@,-]*$ ]] || return 1
  local IFS=,
  for part in $s; do
    [[ -n $part ]] || continue
    [[ $part =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$ ]] || return 1
    [[ $seen == *",$part,"* ]] && continue
    seen+="$part,"
    list+="${list:+,}$part"
  done
  [[ -n $list ]] || return 1
  printf '%s' "$list"
}

if [[ ${1:-} == --check ]]; then
  file=${2:?usage: generate-proxy-allowed-subs.sh --check <file>}
  [[ -f $file ]] || exit 1
  # Exactly one line: a second line, or no final newline, fails.
  [[ $(wc -l < "$file" | tr -d ' ') == 1 ]] || exit 1
  line=$(cat "$file")
  [[ $line == ALLOWED_SUBS=* ]] || exit 1
  value=${line#ALLOWED_SUBS=}
  [[ $(printf '%s\n' "$value" | wc -l | tr -d ' ') == 1 ]] || exit 1
  norm=$(normalize "$value") || exit 1
  [[ $norm == "$value" ]] || exit 1
  exit 0
fi

out=${1:?usage: generate-proxy-allowed-subs.sh <out-file> <floor-subs>}
floor_raw=${2:-}
param=${ALLOWED_SUBS_PARAM:-/memory/proxy-allowed-subs}

[[ -n ${AWS_PROFILE:-} && -n ${AWS_REGION:-} ]] || { warn "AWS_PROFILE and AWS_REGION are required; writing nothing"; exit 0; }

# The floor is what keeps the operator in. If it cannot be trusted, write nothing.
floor=$(normalize "$floor_raw") || { warn "the floor (operator) list is empty or invalid; writing nothing"; exit 0; }

raw=$(aws ssm get-parameter --name "$param" --with-decryption \
        --profile "$AWS_PROFILE" --region "$AWS_REGION" \
        --query Parameter.Value --output text 2>/dev/null) \
  || { warn "cannot read $param; writing nothing"; exit 0; }
ssm_list=$(normalize "$raw") || { warn "$param failed validation (newline, character set, or not an email list); writing nothing"; exit 0; }

list=$(normalize "$floor,$ssm_list") || { warn "combined list failed validation; writing nothing"; exit 0; }
count=$(printf '%s' "$list" | tr ',' '\n' | grep -c .)
(( count <= max_entries )) || { warn "list has $count entries (> $max_entries); writing nothing"; exit 0; }

umask 077
tmp=$(mktemp "${out}.XXXXXX") || { warn "cannot create a temp file next to $out"; exit 1; }
if printf 'ALLOWED_SUBS=%s\n' "$list" > "$tmp" && mv -f "$tmp" "$out"; then
  printf 'generate-proxy-allowed-subs: wrote %s (%d entries)\n' "$out" "$count"
else
  warn "write failed"; exit 1
fi
