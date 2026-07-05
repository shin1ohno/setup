#!/usr/bin/env bash
#
# self-heal-remediate.sh — class C' known-safe remediation executor. Managed by
# cookbooks/self-heal-loops. Do not edit by hand.
#
# THE FENCE IS THIS SCRIPT (setup #642 Phase 2): the resolve loop may run a
# recovery command ONLY by calling this helper, which executes an entry's
# recovery_command ONLY when (host, service) matches EXACTLY in the checked-in
# allowlist. An arbitrary command is NOT runnable — the loop cannot pass a
# command, only a (host, service) key. Anything not listed stays class D
# (needs-human). The allowlist is data, grown only via PR review.
#
# Guards:
#   - exact (host, service) match required, else `refuse` (exit 2)
#   - flap-guard: >= max_kicks_per_window kicks within flap_window_min ->
#     `escalate` (exit 3), do NOT re-kick (promote to a permanent fix / needs-human)
#   - recovery_command must run headless (no interactive sudo) and embeds its own
#     ssh/pct transport
#
# Usage:
#   self-heal-remediate.sh [--dry-run] <host> <service>   # kick (or show) a service
#   self-heal-remediate.sh --check-schema                 # validate the allowlist
# Exit: 0 ok/kicked/would-kick | 2 refuse (not in allowlist / bad usage) |
#       3 escalate (flap) | non-zero = recovery_command's own rc

set -uo pipefail

ALLOWLIST="${SELF_HEAL_REMEDIATE_ALLOWLIST:-/usr/local/share/self-heal/remediation-allowlist.json}"
STATE_DIR="${SELF_HEAL_REMEDIATE_STATE_DIR:-${HOME}/.claude/self-heal-remediate}"

die_refuse() { echo "refuse: $*" >&2; exit 2; }

check_schema() {
  [ -f "${ALLOWLIST}" ] || { echo "FAIL: allowlist not found: ${ALLOWLIST}" >&2; exit 1; }
  jq empty "${ALLOWLIST}" 2>/dev/null || { echo "FAIL: invalid JSON" >&2; exit 1; }
  # every remediations[] entry must carry the 5 required keys with correct types.
  local bad
  bad=$(jq -r '
    [ .remediations[]
      | select(
          (has("host") and (.host|type=="string")) and
          (has("service") and (.service|type=="string")) and
          (has("recovery_command") and (.recovery_command|type=="string")) and
          (has("flap_window_min") and (.flap_window_min|type=="number")) and
          (has("max_kicks_per_window") and (.max_kicks_per_window|type=="number"))
          | not
        )
    ] | length' "${ALLOWLIST}" 2>/dev/null)
  if [ "${bad}" != "0" ]; then echo "FAIL: ${bad} entr(y|ies) missing required keys/types" >&2; exit 1; fi
  echo "schema OK ($(jq '.remediations|length' "${ALLOWLIST}") entr(y|ies))"
  exit 0
}

# --- arg parse ---------------------------------------------------------------
[ "${1:-}" = "--check-schema" ] && check_schema

dry=0
if [ "${1:-}" = "--dry-run" ]; then dry=1; shift; fi
host="${1:-}"; service="${2:-}"
[ -n "${host}" ] && [ -n "${service}" ] || die_refuse "usage: self-heal-remediate.sh [--dry-run] <host> <service>"
[ -f "${ALLOWLIST}" ] || die_refuse "allowlist not found: ${ALLOWLIST}"

entry=$(jq -c --arg h "${host}" --arg s "${service}" \
  '.remediations[] | select(.host==$h and .service==$s)' "${ALLOWLIST}" 2>/dev/null | head -1)
[ -n "${entry}" ] || die_refuse "(${host},${service}) not in allowlist — class D (needs-human)"

cmd=$(jq -r '.recovery_command' <<<"${entry}")
window=$(jq -r '.flap_window_min // 60' <<<"${entry}")
maxk=$(jq -r '.max_kicks_per_window // 1' <<<"${entry}")

# --- flap-guard --------------------------------------------------------------
mkdir -p "${STATE_DIR}" 2>/dev/null || true
key=$(printf '%s\037%s' "${host}" "${service}" | sha1sum 2>/dev/null | cut -d' ' -f1)
kfile="${STATE_DIR}/${key}.kicks"
now=$(date +%s)
cutoff=$(( now - window * 60 ))
recent=0
[ -f "${kfile}" ] && recent=$(awk -v c="${cutoff}" '$1>=c' "${kfile}" 2>/dev/null | wc -l | tr -d ' ')

if [ "${recent}" -ge "${maxk}" ]; then
  echo "escalate: (${host},${service}) kicked ${recent}x in ${window}m (max ${maxk}) — promote to permanent fix (class B) / needs-human, not re-kicking"
  exit 3
fi

if [ "${dry}" = 1 ]; then
  printf '%s\n' "${cmd}"     # exact recovery_command
  exit 0
fi

# --- execute the reviewed recovery command (only allowlist entries reach here) -
echo "kick: (${host},${service}) -> ${cmd}"
bash -c "${cmd}"; rc=$?
# prune expired kicks + record this one
if [ -f "${kfile}" ]; then
  awk -v c="${cutoff}" '$1>=c' "${kfile}" 2>/dev/null > "${kfile}.tmp" && mv -f "${kfile}.tmp" "${kfile}" 2>/dev/null || true
fi
echo "${now}" >> "${kfile}"
echo "kick rc=${rc}"
exit "${rc}"
