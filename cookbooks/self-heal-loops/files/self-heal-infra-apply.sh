#!/usr/bin/env bash
#
# self-heal-infra-apply.sh — Phase 3B (PVE-API-direct). Autonomous CT memory/cores
# resize. Managed by cookbooks/self-heal-loops. Do not edit by hand.
#
# DESIGN (setup#642, docs/self-heal-phase3-security-review.md): the resolve LLM
# proposes only {ct, target_mb, target_cores}; this deterministic wrapper does the
# resize by calling the PVE API directly with a SCOPED token — no terraform, no
# state, no state split. The hard boundary is the token itself: the PVE
# `svc-resize@pve!selfheal` token has role SelfHealResize (VM.Config.Memory,
# VM.Config.CPU, VM.Audit) on a per-CT ACL for the allowlisted CTs ONLY, so even a
# prompt-injected or buggy wrapper CANNOT create/destroy a CT, touch disk/network,
# or reach a non-allowlisted CT — the token physically can't. On top of that the
# wrapper enforces:
#   - non-admin identity (pve-resize AWS profile; refuses if it looks admin /
#     is unusable — fail-closed when unprovisioned).                     [2a]
#   - allowlist ∩ [min,max] ceiling+FLOOR + INCREASE-ONLY (never shrink). [1a]
#   - per-CT daily budget (cooldown vs host RAM oversubscription).        [3d]
#   - re-reads the CT config after the PUT and confirms it reflects the request.
# After a successful resize it updates contracts/devices.json (memory/cores) and
# commits, so the next human `terraform apply` sees no drift.
#
# Usage:
#   self-heal-infra-apply.sh [--dry-run] <ct> <target_mb> <target_cores>
#   self-heal-infra-apply.sh --self-test
# Exit: 0 resized/would-resize | 2 refuse (off-list / not least-priv / usage)
#       | 3 abort (API/verify failed) | 4 refuse (budget) | 5 refuse (decrease/floor)

set -uo pipefail

HM_DIR="${SELF_HEAL_HM_DIR:-${HOME}/ManagedProjects/home-monitor}"
DEVICES="${SELF_HEAL_DEVICES_JSON:-${HM_DIR}/contracts/devices.json}"
ALLOWLIST="${SELF_HEAL_INFRA_ALLOWLIST:-/usr/local/share/self-heal/infra-resize-allowlist.json}"
STATE_DIR="${SELF_HEAL_INFRA_STATE_DIR:-${HOME}/.claude/self-heal-infra}"
AWS_PROFILE_RESIZE="${SELF_HEAL_INFRA_AWS_PROFILE:-pve-resize}"
RESIZE_TOKEN_SSM="${SELF_HEAL_RESIZE_TOKEN_SSM:-/pve/resize-token}"
AWS_REGION_RESIZE="${SELF_HEAL_INFRA_AWS_REGION:-ap-northeast-1}"
PVE_NODE="${SELF_HEAL_PVE_NODE:-pro}"
# TLS: verify the PVE API cert against the pinned PVE root CA (the cert's SAN
# includes the LAN IP, so --cacert verifies by IP with no --resolve). Fail-closed
# if the CA is absent, UNLESS SELF_HEAL_ALLOW_INSECURE_PVE=1 is explicitly set
# (bootstrap-only opt-in; production runs must have the CA and verify).
PVE_CA="${SELF_HEAL_PVE_CA:-/etc/self-heal/pve-ca.pem}"

log() { echo "[$(date -u +%FT%TZ)] $*"; }
refuse() { echo "refuse: $*" >&2; exit "${2:-2}"; }

# --- pure: validate a requested resize (allowlist + current + increase-only) ---
# echoes "ok" or "refuse:<reason>"; rc 0/nonzero
validate_resize() {
  local ct="$1" mb="$2" cores="$3" entry cur_mb cur_cores min_mb max_mb min_c max_c budget used today
  case "${mb}" in ''|*[!0-9]*) echo "refuse:target_mb not numeric"; return 2 ;; esac
  case "${cores}" in ''|*[!0-9]*) echo "refuse:target_cores not numeric"; return 2 ;; esac
  [ -f "${ALLOWLIST}" ] || { echo "refuse:allowlist missing"; return 2; }
  entry=$(jq -c --arg c "${ct}" '.resizable[]? | select(.ct==$c)' "${ALLOWLIST}" 2>/dev/null | head -1)
  [ -n "${entry}" ] || { echo "refuse:${ct} not in infra-resize-allowlist"; return 2; }

  min_mb=$(jq -r '.min_memory_mb' <<<"${entry}"); max_mb=$(jq -r '.max_memory_mb' <<<"${entry}")
  min_c=$(jq -r '.min_cores' <<<"${entry}");      max_c=$(jq -r '.max_cores' <<<"${entry}")
  budget=$(jq -r '.per_ct_daily_budget // 1' <<<"${entry}")

  { [ "${mb}" -ge "${min_mb}" ] && [ "${mb}" -le "${max_mb}" ]; } || { echo "refuse:target_mb ${mb} outside [${min_mb},${max_mb}]"; return 5; }
  { [ "${cores}" -ge "${min_c}" ] && [ "${cores}" -le "${max_c}" ]; } || { echo "refuse:target_cores ${cores} outside [${min_c},${max_c}]"; return 5; }

  [ -f "${DEVICES}" ] || { echo "refuse:devices.json missing"; return 2; }
  cur_mb=$(jq -r --arg c "${ct}" '.devices[$c].lxc.memory' "${DEVICES}" 2>/dev/null)
  cur_cores=$(jq -r --arg c "${ct}" '.devices[$c].lxc.cores' "${DEVICES}" 2>/dev/null)
  case "${cur_mb}${cur_cores}" in *null*|'') echo "refuse:${ct} not found in devices.json"; return 2 ;; esac
  { [ "${mb}" -ge "${cur_mb}" ] && [ "${cores}" -ge "${cur_cores}" ]; } || { echo "refuse:decrease not allowed (cur ${cur_mb}MB/${cur_cores}c -> ${mb}MB/${cores}c)"; return 5; }
  { [ "${mb}" -gt "${cur_mb}" ] || [ "${cores}" -gt "${cur_cores}" ]; } || { echo "refuse:no-op (already ${cur_mb}MB/${cur_cores}c)"; return 5; }

  today=$(date -u +%Y-%m-%d)
  used=0
  [ -f "${STATE_DIR}/${ct}.applies" ] && used=$(grep -c "^${today} " "${STATE_DIR}/${ct}.applies" 2>/dev/null || echo 0)
  [ "${used}" -lt "${budget}" ] || { echo "refuse:daily budget ${budget} reached for ${ct} (${used} today)"; return 4; }

  echo "ok"; return 0
}

# --- least-privilege identity assertion (fail-closed) ----------------------
assert_least_privilege() {
  local arn
  arn=$(aws sts get-caller-identity --profile "${AWS_PROFILE_RESIZE}" --query Arn --output text 2>/dev/null)
  [ -n "${arn}" ] && [ "${arn}" != "None" ] || refuse "AWS profile '${AWS_PROFILE_RESIZE}' unusable (unprovisioned?) — fail-closed" 2
  case "${arn}" in
    *:user/sh1admin|*:root|*[Aa]dmin*) refuse "identity ${arn} looks admin — refusing (resize path must be least-priv ${AWS_PROFILE_RESIZE})" 2 ;;
  esac
  log "identity ${arn} (least-priv OK)"
}

# --- PVE API helpers (scoped token; header via a mode-600 curl config so the
#     token never lands in argv/ps) -----------------------------------------
_pve_endpoint() {
  local ip
  ip=$(jq -r '.devices["pve-host"].ip // .devices["pve-host"].lxc.ip // empty' "${DEVICES}" 2>/dev/null)
  echo "https://${ip:-192.168.1.10}:8006"
}
# _pve_curl <token> <method> <path> [data]  -> response body on stdout
_pve_curl() {
  local tok="$1" method="$2" path="$3" data="${4:-}" cfg rc
  local -a tls
  if [ -f "${PVE_CA}" ]; then
    tls=(--cacert "${PVE_CA}")            # verify against the pinned PVE root CA
  elif [ "${SELF_HEAL_ALLOW_INSECURE_PVE:-0}" = "1" ]; then
    tls=(-k)                              # explicit bootstrap opt-in ONLY
  else
    echo "refuse: PVE CA ${PVE_CA} absent and SELF_HEAL_ALLOW_INSECURE_PVE!=1 — fail-closed on TLS" >&2
    return 7
  fi
  cfg=$(mktemp); chmod 600 "${cfg}"
  printf 'header = "Authorization: PVEAPIToken=%s"\n' "${tok}" > "${cfg}"
  if [ -n "${data}" ]; then
    curl -s --max-time 20 "${tls[@]}" -K "${cfg}" -X "${method}" --data "${data}" "$(_pve_endpoint)${path}"; rc=$?
  else
    curl -s --max-time 20 "${tls[@]}" -K "${cfg}" -X "${method}" "$(_pve_endpoint)${path}"; rc=$?
  fi
  rm -f "${cfg}"
  return "${rc}"
}

# --- main resize flow (PVE-API-direct) -------------------------------------
do_resize() {
  local dry="$1" ct="$2" mb="$3" cores="$4" v rc ct_id tok resp new_mb new_cores
  v=$(validate_resize "${ct}" "${mb}" "${cores}"); rc=$?
  [ "${v}" = "ok" ] || refuse "${v#refuse:}" "${rc}"

  assert_least_privilege

  ct_id=$(jq -r --arg c "${ct}" '.devices[$c].lxc.ct_id' "${DEVICES}" 2>/dev/null)
  case "${ct_id}" in ''|*[!0-9]*) refuse "no numeric ct_id for ${ct} in devices.json" 2 ;; esac

  tok=$(aws ssm get-parameter --name "${RESIZE_TOKEN_SSM}" --with-decryption \
          --profile "${AWS_PROFILE_RESIZE}" --region "${AWS_REGION_RESIZE}" \
          --query 'Parameter.Value' --output text 2>/dev/null)
  [ -n "${tok}" ] && [ "${tok}" != "None" ] || refuse "could not fetch ${RESIZE_TOKEN_SSM} via ${AWS_PROFILE_RESIZE} — fail-closed" 2

  if [ "${dry}" = 1 ]; then
    # confirm the token can READ the target (VM.Audit) — proves reachability +
    # that the CT is within the token's per-CT ACL — without mutating anything.
    resp=$(_pve_curl "${tok}" GET "/api2/json/nodes/${PVE_NODE}/lxc/${ct_id}/config")
    unset tok
    new_mb=$(jq -r '.data.memory // empty' <<<"${resp}" 2>/dev/null)
    [ -n "${new_mb}" ] || refuse "dry-run: cannot read CT ${ct_id} config via scoped token (ACL? reachability?)" 3
    log "dry-run: ${ct}(${ct_id}) readable=${new_mb}MB, would PUT ${mb}MB/${cores}c"
    exit 0
  fi

  # PUT the new memory/cores (VM.Config.Memory / VM.Config.CPU).
  _pve_curl "${tok}" PUT "/api2/json/nodes/${PVE_NODE}/lxc/${ct_id}/config" "memory=${mb}&cores=${cores}" >/dev/null
  sleep 2
  resp=$(_pve_curl "${tok}" GET "/api2/json/nodes/${PVE_NODE}/lxc/${ct_id}/config")
  unset tok
  new_mb=$(jq -r '.data.memory // empty' <<<"${resp}")
  new_cores=$(jq -r '.data.cores // empty' <<<"${resp}")
  if [ "${new_mb}" != "${mb}" ] || [ "${new_cores}" != "${cores}" ]; then
    refuse "post-PUT verify failed: CT ${ct_id} reports ${new_mb}MB/${new_cores}c, wanted ${mb}MB/${cores}c" 3
  fi

  # drift consistency: update devices.json to the new desired state + commit, so a
  # later human `terraform apply` does not revert the resize.
  jq --arg c "${ct}" --argjson mb "${mb}" --argjson cores "${cores}" \
    '.devices[$c].lxc.memory = $mb | .devices[$c].lxc.cores = $cores' "${DEVICES}" > "${DEVICES}.new" \
    && mv "${DEVICES}.new" "${DEVICES}"
  git -C "${HM_DIR}" add contracts/devices.json 2>/dev/null
  git -C "${HM_DIR}" commit -m "self-heal: resize ${ct} -> ${mb}MB/${cores}c (autonomous, PVE-API + devices.json sync)" >/dev/null 2>&1
  git -C "${HM_DIR}" push origin HEAD:main >/dev/null 2>&1 || log "WARN: devices.json push failed (live resize applied; drift until reconciled)"

  mkdir -p "${STATE_DIR}"; echo "$(date -u +%Y-%m-%d) $(date -u +%FT%TZ) ${mb}MB/${cores}c" >> "${STATE_DIR}/${ct}.applies"
  log "resized ${ct}(${ct_id}) -> ${new_mb}MB/${new_cores}c (verified)"
  exit 0
}

# --- self-test (hermetic: pure validate with fixtures) ---------------------
self_test() {
  local fail=0 tmp; tmp=$(mktemp -d)
  _a() { [ "$1" = "$2" ] || { echo "FAIL: $3 (got '$1' want '$2')"; fail=1; }; }
  cat > "${tmp}/allow.json" <<'JSON'
{"resizable":[{"ct":"foo","ct_id":199,"allow_fields":["memory","cores"],"min_memory_mb":1024,"max_memory_mb":4096,"min_cores":1,"max_cores":4,"per_ct_daily_budget":2}]}
JSON
  cat > "${tmp}/devices.json" <<'JSON'
{"devices":{"foo":{"kind":"lxc","lxc":{"ct_id":199,"memory":2048,"cores":2}}}}
JSON
  ALLOWLIST="${tmp}/allow.json" DEVICES="${tmp}/devices.json" STATE_DIR="${tmp}/state"
  _a "$(validate_resize foo 3072 2)" ok                          "increase in-range -> ok"
  _a "$(validate_resize foo 1024 1 | cut -c1-6)" refuse          "decrease -> refuse"
  _a "$(validate_resize foo 8192 2 | cut -c1-6)" refuse          "over ceiling -> refuse"
  _a "$(validate_resize foo 512 2 | cut -c1-6)"  refuse          "below floor -> refuse"
  _a "$(validate_resize bar 3072 2 | cut -c1-6)" refuse          "off-list CT -> refuse"
  _a "$(validate_resize foo 2048 2 | cut -c1-6)" refuse          "no-op -> refuse"
  mkdir -p "${tmp}/state"; today=$(date -u +%Y-%m-%d)
  printf '%s x\n%s y\n' "${today}" "${today}" > "${tmp}/state/foo.applies"
  _a "$(validate_resize foo 3072 2 | cut -c1-6)" refuse          "daily budget exhausted -> refuse"
  rm -rf "${tmp}"
  if [ "${fail}" = 0 ]; then echo "self-test: PASS"; return 0; fi
  echo "self-test: FAIL"; return 1
}

case "${1:-}" in
  --self-test) self_test ;;
  --dry-run)   shift; [ $# -eq 3 ] || refuse "usage: --dry-run <ct> <target_mb> <target_cores>"; do_resize 1 "$1" "$2" "$3" ;;
  '' )         refuse "usage: self-heal-infra-apply.sh [--dry-run] <ct> <target_mb> <target_cores> | --self-test" ;;
  * )          [ $# -eq 3 ] || refuse "usage: self-heal-infra-apply.sh <ct> <target_mb> <target_cores>"; do_resize 0 "$1" "$2" "$3" ;;
esac
