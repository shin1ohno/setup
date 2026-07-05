#!/usr/bin/env bash
#
# self-heal-infra-apply.sh — Phase 3B hardened 案B. THE ONLY PLACE THAT HOLDS THE
# `terraform apply` VERB for autonomous CT resize. Managed by
# cookbooks/self-heal-loops. Do not edit by hand.
#
# The resolve LLM never runs terraform apply itself — it proposes only
# {ct, target_mb, target_cores}; this deterministic wrapper enforces the whole
# security envelope (docs/self-heal-phase3-security-review.md), so a
# prompt-injected or mis-reasoning loop cannot exceed it:
#   - runs under the NON-ADMIN pve-resize AWS profile only; refuses if the
#     identity looks admin or the profile is unusable (fail-closed when
#     unprovisioned — same safety as boundary #8 needs-human).            [2a/2c]
#   - allowlist ∩ [min,max] ceiling+FLOOR, INCREASE-ONLY (never shrink).  [1a]
#   - per-CT daily budget (cooldown vs host RAM oversubscription).        [3d]
#   - terraform plan -> show -json, FAIL-CLOSED full scan: exactly the target CT
#     is ["update"], every other change is no-op/read, nothing is create/delete
#     (catches replace), 0 to destroy.                                    [1b]
#   - requires terraform.tfvars present (else plan hangs on var prompts).  [4a]
#   - only edits contracts/devices.json memory/cores (deterministic jq); rootfs
#     is never touched.
#
# Usage:
#   self-heal-infra-apply.sh [--dry-run] <ct> <target_mb> <target_cores>
#   self-heal-infra-apply.sh --self-test
# Exit: 0 applied/would-apply | 2 refuse (off-list / bad usage / not least-priv)
#       | 3 abort (plan gate failed) | 4 refuse (budget) | 5 refuse (decrease/floor)
#       | 6 refuse (tfvars absent)

set -uo pipefail

HM_DIR="${SELF_HEAL_HM_DIR:-${HOME}/ManagedProjects/home-monitor}"
DEVICES="${SELF_HEAL_DEVICES_JSON:-${HM_DIR}/contracts/devices.json}"
ALLOWLIST="${SELF_HEAL_INFRA_ALLOWLIST:-/usr/local/share/self-heal/infra-resize-allowlist.json}"
STATE_DIR="${SELF_HEAL_INFRA_STATE_DIR:-${HOME}/.claude/self-heal-infra}"
AWS_PROFILE_RESIZE="${SELF_HEAL_INFRA_AWS_PROFILE:-pve-resize}"

log() { echo "[$(date -u +%FT%TZ)] $*"; }
refuse() { echo "refuse: $*" >&2; exit "${2:-2}"; }

# --- pure: validate a requested resize against the allowlist + current state ---
# validate_resize <ct> <mb> <cores> ; echoes "ok" or "refuse:<reason>"; rc 0/nonzero
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

  # ceiling + FLOOR
  { [ "${mb}" -ge "${min_mb}" ] && [ "${mb}" -le "${max_mb}" ]; } || { echo "refuse:target_mb ${mb} outside [${min_mb},${max_mb}]"; return 5; }
  { [ "${cores}" -ge "${min_c}" ] && [ "${cores}" -le "${max_c}" ]; } || { echo "refuse:target_cores ${cores} outside [${min_c},${max_c}]"; return 5; }

  # increase-only vs the current declared value (devices.json = TF desired state)
  [ -f "${DEVICES}" ] || { echo "refuse:devices.json missing"; return 2; }
  cur_mb=$(jq -r --arg c "${ct}" '.devices[$c].lxc.memory' "${DEVICES}" 2>/dev/null)
  cur_cores=$(jq -r --arg c "${ct}" '.devices[$c].lxc.cores' "${DEVICES}" 2>/dev/null)
  case "${cur_mb}${cur_cores}" in *null*|'') echo "refuse:${ct} not found in devices.json"; return 2 ;; esac
  { [ "${mb}" -ge "${cur_mb}" ] && [ "${cores}" -ge "${cur_cores}" ]; } || { echo "refuse:decrease not allowed (cur ${cur_mb}MB/${cur_cores}c -> ${mb}MB/${cores}c)"; return 5; }
  { [ "${mb}" -gt "${cur_mb}" ] || [ "${cores}" -gt "${cur_cores}" ]; } || { echo "refuse:no-op (already ${cur_mb}MB/${cur_cores}c)"; return 5; }

  # per-CT daily budget
  today=$(date -u +%Y-%m-%d)
  used=0
  [ -f "${STATE_DIR}/${ct}.applies" ] && used=$(grep -c "^${today} " "${STATE_DIR}/${ct}.applies" 2>/dev/null || echo 0)
  [ "${used}" -lt "${budget}" ] || { echo "refuse:daily budget ${budget} reached for ${ct} (${used} today)"; return 4; }

  echo "ok"; return 0
}

# --- pure: fail-closed gate over a `terraform show -json` plan --------------
# gate_plan_json <planjson_file> <ct>  ; rc 0 approve / 1 abort
gate_plan_json() {
  local file="$1" ct="$2" target="proxmox_virtual_environment_container.lxc[\"$2\"]"
  [ -f "${file}" ] || return 1
  jq -e --arg t "${target}" '
    ([.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])]) as $u
    | ($u | length) == 1
      and ($u[0].address == $t)
      and ($u[0].change.actions == ["update"])
      and (([.resource_changes[]?.change.actions[]?] | any(. == "delete" or . == "create")) | not)
  ' "${file}" >/dev/null 2>&1
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

# --- main resize flow ------------------------------------------------------
do_resize() {
  local dry="$1" ct="$2" mb="$3" cores="$4" v rc plan_json
  v=$(validate_resize "${ct}" "${mb}" "${cores}"); rc=$?
  [ "${v}" = "ok" ] || refuse "${v#refuse:}" "${rc}"

  assert_least_privilege
  [ -f "${HM_DIR}/terraform.tfvars" ] || refuse "terraform.tfvars absent on this host — plan would hang on var prompts" 6

  # deterministic edit (memory/cores only) on a scratch copy of devices.json
  local bak; bak=$(mktemp)
  cp "${DEVICES}" "${bak}"
  jq --arg c "${ct}" --argjson mb "${mb}" --argjson cores "${cores}" \
    '.devices[$c].lxc.memory = $mb | .devices[$c].lxc.cores = $cores' "${DEVICES}" > "${DEVICES}.new" \
    && mv "${DEVICES}.new" "${DEVICES}" || { cp "${bak}" "${DEVICES}"; rm -f "${bak}"; refuse "devices.json edit failed" 2; }

  plan_json=$(mktemp)
  local ok=1
  if AWS_PROFILE="${AWS_PROFILE_RESIZE}" terraform -chdir="${HM_DIR}" plan -out="${HM_DIR}/.selfheal.tfplan" >/dev/null 2>&1 \
     && AWS_PROFILE="${AWS_PROFILE_RESIZE}" terraform -chdir="${HM_DIR}" show -json "${HM_DIR}/.selfheal.tfplan" > "${plan_json}" 2>/dev/null \
     && gate_plan_json "${plan_json}" "${ct}"; then ok=0; fi

  if [ "${ok}" != 0 ]; then
    cp "${bak}" "${DEVICES}"; rm -f "${bak}" "${plan_json}" "${HM_DIR}/.selfheal.tfplan"
    refuse "plan gate failed (not a clean in-place ${ct} memory/cores update) — abort to needs-human" 3
  fi

  if [ "${dry}" = 1 ]; then
    cp "${bak}" "${DEVICES}"; rm -f "${bak}" "${plan_json}" "${HM_DIR}/.selfheal.tfplan"
    log "dry-run: plan gate PASSED for ${ct} -> ${mb}MB/${cores}c (would commit + apply)"
    exit 0
  fi

  # real apply: commit the devices.json edit to home-monitor main, then apply the
  # inspected planfile verbatim. Record the apply against the daily budget.
  git -C "${HM_DIR}" add contracts/devices.json
  git -C "${HM_DIR}" commit -m "self-heal: resize ${ct} -> ${mb}MB/${cores}c (autonomous, plan-gated)" >/dev/null 2>&1
  git -C "${HM_DIR}" push origin HEAD:main >/dev/null 2>&1 || { rm -f "${bak}" "${plan_json}"; refuse "push failed" 2; }
  AWS_PROFILE="${AWS_PROFILE_RESIZE}" terraform -chdir="${HM_DIR}" apply "${HM_DIR}/.selfheal.tfplan"; rc=$?
  mkdir -p "${STATE_DIR}"; echo "$(date -u +%Y-%m-%d) $(date -u +%FT%TZ) ${mb}MB/${cores}c" >> "${STATE_DIR}/${ct}.applies"
  rm -f "${bak}" "${plan_json}" "${HM_DIR}/.selfheal.tfplan"
  log "applied ${ct} -> ${mb}MB/${cores}c rc=${rc}"
  exit "${rc}"
}

# --- self-test (hermetic: pure validate + gate_plan_json with fixtures) -----
self_test() {
  local fail=0 tmp; tmp=$(mktemp -d)
  _a() { [ "$1" = "$2" ] || { echo "FAIL: $3 (got '$1' want '$2')"; fail=1; }; }

  # fixture allowlist + devices.json
  cat > "${tmp}/allow.json" <<'JSON'
{"resizable":[{"ct":"foo","ct_id":199,"allow_fields":["memory","cores"],"min_memory_mb":1024,"max_memory_mb":4096,"min_cores":1,"max_cores":4,"per_ct_daily_budget":2}]}
JSON
  cat > "${tmp}/devices.json" <<'JSON'
{"devices":{"foo":{"kind":"lxc","lxc":{"ct_id":199,"memory":2048,"cores":2}}}}
JSON
  ALLOWLIST="${tmp}/allow.json" DEVICES="${tmp}/devices.json" STATE_DIR="${tmp}/state"

  _a "$(validate_resize foo 3072 2)" ok                               "increase memory in-range -> ok"
  _a "$(validate_resize foo 1024 1 | cut -c1-6)" refuse               "decrease -> refuse"
  _a "$(validate_resize foo 8192 2 | cut -c1-6)" refuse               "over ceiling -> refuse"
  _a "$(validate_resize foo 512 2 | cut -c1-6)"  refuse               "below floor -> refuse"
  _a "$(validate_resize bar 3072 2 | cut -c1-6)" refuse               "off-list CT -> refuse"
  _a "$(validate_resize foo 2048 2 | cut -c1-6)" refuse               "no-op (same) -> refuse"
  # budget: seed 2 applies today -> next refuse
  mkdir -p "${tmp}/state"; today=$(date -u +%Y-%m-%d)
  printf '%s x\n%s y\n' "${today}" "${today}" > "${tmp}/state/foo.applies"
  _a "$(validate_resize foo 3072 2 | cut -c1-6)" refuse               "daily budget exhausted -> refuse"
  rm -f "${tmp}/state/foo.applies"

  # gate_plan_json fixtures
  cat > "${tmp}/planA.json" <<'JSON'
{"resource_changes":[
  {"address":"proxmox_virtual_environment_container.lxc[\"foo\"]","change":{"actions":["update"]}},
  {"address":"data.aws_ssm_parameter.x","change":{"actions":["read"]}},
  {"address":"aws_iam_user.y","change":{"actions":["no-op"]}}]}
JSON
  gate_plan_json "${tmp}/planA.json" foo && _a ok ok "planA in-place target update -> approve" || _a abort ok "planA should approve"

  cat > "${tmp}/planB.json" <<'JSON'
{"resource_changes":[
  {"address":"proxmox_virtual_environment_container.lxc[\"foo\"]","change":{"actions":["update"]}},
  {"address":"aws_s3_bucket.z","change":{"actions":["delete"]}}]}
JSON
  gate_plan_json "${tmp}/planB.json" foo && _a approve abort "planB has a delete -> should abort" || _a ok ok "planB delete -> abort"

  cat > "${tmp}/planC.json" <<'JSON'
{"resource_changes":[
  {"address":"proxmox_virtual_environment_container.lxc[\"foo\"]","change":{"actions":["delete","create"]}}]}
JSON
  gate_plan_json "${tmp}/planC.json" foo && _a approve abort "planC replace -> should abort" || _a ok ok "planC replace -> abort"

  rm -rf "${tmp}"
  if [ "${fail}" = 0 ]; then echo "self-test: PASS"; return 0; fi
  echo "self-test: FAIL"; return 1
}

# --- dispatch --------------------------------------------------------------
case "${1:-}" in
  --self-test) self_test ;;
  --dry-run)   shift; [ $# -eq 3 ] || refuse "usage: --dry-run <ct> <target_mb> <target_cores>"; do_resize 1 "$1" "$2" "$3" ;;
  '' )         refuse "usage: self-heal-infra-apply.sh [--dry-run] <ct> <target_mb> <target_cores> | --self-test" ;;
  * )          [ $# -eq 3 ] || refuse "usage: self-heal-infra-apply.sh <ct> <target_mb> <target_cores>"; do_resize 0 "$1" "$2" "$3" ;;
esac
