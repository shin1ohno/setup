#!/usr/bin/env bash
#
# self-heal-create — fleet alert → GitHub issue sync (PURE SHELL, no LLM).
# Managed by cookbooks/self-heal-loops. Do not edit by hand.
#
# Replaces the previous `claude -p` create loop: the ES self-heal-state →
# GitHub issue sync is a deterministic SET DIFF keyed by sha1(dedup_key), so it
# needs no model reasoning. This is the single source of truth for the sync
# logic; the self-heal-create SKILL.md is a thin wrapper that runs this script.
#
# Reads ES self-heal-state (status:open) and the open self-heal-labelled issues
# in shin1ohno/setup, then:
#   NEW        (ES open, no open issue)  -> reopen a <24h same-marker closed
#                                           issue (flap) else gh issue create
#   RESOLVED   (open issue, gone from ES) -> gh issue close + comment
#                                            (NEVER closes self-heal-needs-human)
#   CONTINUING (both)                     -> no-op (dedup)
#
# Invariant safety boundaries (must always hold):
#   1. READ-ONLY on ES (GET only; the observer writes state, never this script).
#   2. Only shin1ohno/setup issues with the `self-heal` label.
#   3. No code / PR / merge — only issue open/close + comment.
#   4. Never touch an issue without a `<!-- self-heal-key:... -->` marker.
#   5. Never close an open issue labelled `self-heal-needs-human`.
#   6. ES unreachable OR elastic pw unavailable -> STOP (do nothing; never
#      mass-close). "empty != unreachable": ES reachable with 0 open docs is a
#      VALID empty set (all resolved) and proceeds to the RESOLVED sweep.
#
# marker = sha1(dedup_key), computed with the SAME expression the observer uses
# for the ES doc _id (`printf '%s' "$dk" | sha1sum | cut -d' ' -f1`), so an
# issue's marker and its ES doc are 1:1.
#
# SELF_HEAL_DRY_RUN=1 -> do every read (ES GET, gh list) but PRINT would-actions
# instead of running gh create/reopen/close. Side-effect-free verification.
#
# Diagnostics go to stderr (the cron wrapper captures them); the final one-line
# summary goes to stdout. Exit is ALWAYS 0 except usage errors — a STOP is a
# clean no-op, not a failure.

set -uo pipefail

# --- config (script owns the defaults = single source of truth) -------------
REPO="${SELF_HEAL_REPO:-shin1ohno/setup}"
LABEL="${SELF_HEAL_LABEL:-self-heal}"
NEEDS_HUMAN_LABEL="${SELF_HEAL_NEEDS_HUMAN_LABEL:-self-heal-needs-human}"
ES_HOSTS="${SELF_HEAL_ES_HOSTS:-https://es-0.home.local:9200 https://es-1.home.local:9200 https://es-2.home.local:9200}"
ES_CA="${SELF_HEAL_ES_CA:-/etc/elastic-agent/certs/ca.crt}"
ELASTIC_PW_SSM="${SELF_HEAL_ELASTIC_PW_SSM:-/monitoring/elastic/elastic-password}"
AWS_PROFILE_="${SELF_HEAL_AWS_PROFILE:-pve-bootstrap-ssm}"
AWS_REGION_="${SELF_HEAL_AWS_REGION:-ap-northeast-1}"
STATE_INDEX="${SELF_HEAL_STATE_INDEX:-self-heal-state}"
DRY_RUN="${SELF_HEAL_DRY_RUN:-0}"
# ES password cache (cut kms:Decrypt: this loop runs every 2 min and each SSM
# get-parameter --with-decryption is one kms:Decrypt). Mirrors the CT111
# observer's get_pw cache, but on a per-host tmpfs path: the loop runs on pro-dev
# via `runuser -l`, where /run/self-heal (root-owned) is not writable, while
# $XDG_RUNTIME_DIR (=/run/user/<uid>, tmpfs, 0700 user-owned, kept alive by
# linger=yes) is. The secret therefore never touches persistent disk and is
# cleared on reboot. Caching is BEST-EFFORT — any failure falls back to a direct
# SSM fetch, so a missing/unwritable runtime dir never blocks the sync.
PW_CACHE="${SELF_HEAL_PW_CACHE:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/self-heal/elastic-pw.cache}"
PW_CACHE_TTL="${SELF_HEAL_PW_CACHE_TTL:-1800}"  # 30 min; matches the observer

CURL=/usr/bin/curl
ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(ts)] self-heal-create: $*" >&2; }
sha1_of() { printf '%s' "$1" | sha1sum | cut -d' ' -f1; }

dry() { [ "$DRY_RUN" = "1" ]; }

# get_pw: serve the elastic password from the tmpfs cache when fresh, else fetch
# from SSM (one kms:Decrypt) and refresh the cache. Empty output => unavailable.
get_pw() {
  local pw age
  if [ -f "$PW_CACHE" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$PW_CACHE" 2>/dev/null || echo 0) ))
    if [ "$age" -ge 0 ] && [ "$age" -lt "$PW_CACHE_TTL" ]; then
      pw=$(cat "$PW_CACHE" 2>/dev/null)
      [ -n "$pw" ] && { printf '%s' "$pw"; return 0; }
    fi
  fi
  pw=$(aws ssm get-parameter --name "$ELASTIC_PW_SSM" --with-decryption \
        --query 'Parameter.Value' --output text \
        --profile "$AWS_PROFILE_" --region "$AWS_REGION_" 2>/dev/null)
  [ -n "$pw" ] && [ "$pw" != "None" ] || return 1
  # Best-effort cache write (0600 on tmpfs). Never block the sync on failure.
  if mkdir -p "$(dirname "$PW_CACHE")" 2>/dev/null; then
    ( umask 077; printf '%s' "$pw" > "$PW_CACHE" 2>/dev/null ) || true
  fi
  printf '%s' "$pw"
}

# --- Step 0: elastic password (STOP on failure = boundary 6) -----------------
ES_PW=$(get_pw)
if [ -z "$ES_PW" ] || [ "$ES_PW" = "None" ]; then
  log "STOP: elastic pw unavailable (cache miss + SSM $ELASTIC_PW_SSM, profile=$AWS_PROFILE_)"
  echo "self-heal-create: STOP (elastic pw unavailable)"
  exit 0
fi

# --- es_get <path> <body> ----------------------------------------------------
# rc 0 = some host answered (hits 0 is a VALID empty; stdout has the body).
# rc 1 = ALL hosts failed (true unreachable; only here may we STOP).
# Host split via printf|tr + here-doc while-read (no pipe, so a real subshell is
# avoided and the function's return takes effect). curl by absolute path; var
# name `epath` (never `path`, a zsh $PATH-linked special array).
es_get() {
  local epath="$1" ebody="$2" ehost eout
  while IFS= read -r ehost; do
    [ -n "$ehost" ] || continue
    eout=$("$CURL" -s -m 15 --cacert "$ES_CA" -u "elastic:${ES_PW}" \
             -H 'Content-Type: application/json' -X GET "${ehost}${epath}" -d "$ebody" 2>/dev/null)
    if [ -n "$eout" ] && ! printf '%s' "$eout" | grep -q '"error"[[:space:]]*:'; then
      printf '%s' "$eout"; return 0
    fi
  done <<EOF
$(printf '%s' "$ES_HOSTS" | tr ' ' '\n')
EOF
  return 1
}

# --- Step 1: ES open set (truth source) --------------------------------------
es_json=$(es_get "/${STATE_INDEX}/_search" \
  '{"size":1000,"query":{"term":{"status":"open"}},
    "_source":["dedup_key","source","severity","observed_value","first_seen","host","service"]}')
if [ $? -ne 0 ]; then
  log "STOP: ES unreachable (all hosts failed) — not closing anything (boundary 6)"
  echo "self-heal-create: STOP (ES unreachable)"
  exit 0
fi

# Total open docs (pre-guard) and the null-dedup_key-guarded valid rows.
total_open=$(printf '%s' "$es_json" | jq -r '[.hits.hits[]?._source] | length' 2>/dev/null || echo 0)
# Records are US-delimited (0x1F), NOT tab: `IFS=$'\t' read` collapses
# consecutive tabs (tab is IFS-whitespace), so an empty middle field (e.g. an
# empty observed_value, or the always-empty host/service the observer omits)
# would shift later columns left. US is non-whitespace → empty fields are
# preserved positionally. dedup_key stays RAW (field 1) so its sha1 matches the
# observer's _id byte-for-byte; only the display fields are newline/tab/US-sanitised.
valid_tsv=$(printf '%s' "$es_json" | jq -r '
  def san: gsub("[\u001f\r\n\t]"; " ");
  .hits.hits[]?._source
  | select(.dedup_key != null
           and (.dedup_key|tostring|gsub("^\\s+|\\s+$";"")) != ""
           and .dedup_key != "null")
  | [(.dedup_key|tostring),
     ((.source//"")|san), ((.severity//"")|san), ((.observed_value//"")|san),
     ((.first_seen//"")|san), ((.host//"")|san), ((.service//"")|san)]
  | join("\u001f")' 2>/dev/null)

declare -A ES_DK ES_SRC ES_SEV ES_OBS ES_FS ES_HOST ES_SVC
valid_count=0
if [ -n "$valid_tsv" ]; then
  while IFS=$'\037' read -r dk src sev obs fs host svc; do
    [ -n "$dk" ] || continue
    k=$(sha1_of "$dk")
    ES_DK[$k]="$dk"; ES_SRC[$k]="$src"; ES_SEV[$k]="$sev"; ES_OBS[$k]="$obs"
    ES_FS[$k]="$fs"; ES_HOST[$k]="$host"; ES_SVC[$k]="$svc"
    valid_count=$((valid_count + 1))
  done <<< "$valid_tsv"
fi
skipped_null=$((total_open - valid_count))
[ "$skipped_null" -gt 0 ] && log "skipped $skipped_null self-heal-state doc(s) with empty/null dedup_key"

# --- Step 2: GitHub open self-heal issues, keyed by marker -------------------
gh_json=$(gh issue list --repo "$REPO" --label "$LABEL" --state open \
  --limit 500 --json number,body,labels 2>/dev/null)
if [ -z "$gh_json" ]; then
  log "STOP: could not list GitHub issues (gh returned empty) — not creating/closing"
  echo "self-heal-create: STOP (gh issue list failed)"
  exit 0
fi

# Per issue: number<US>marker<US>needs_human(0/1), US (0x1F)-delimited — NOT tab.
# A marker-less issue has an EMPTY marker (middle field); `IFS=$'\t' read` would
# collapse the resulting consecutive tabs and shift the needs-human flag into
# `marker`, so the empty-marker guard misses and a manually-created marker-less
# issue gets auto-closed (boundary 4 violation). US is non-whitespace, so the
# empty marker is preserved and the guard fires. `?`-guarded capture so a
# no-match body doesn't abort the whole filter.
gh_tsv=$(printf '%s' "$gh_json" | jq -r '
  .[]
  | [(.number|tostring),
     ((( .body // "" ) | capture("self-heal-key:(?<k>[0-9a-f]{40})") | .k)? // ""),
     (if (.labels|map(.name)|index("'"$NEEDS_HUMAN_LABEL"'")) then "1" else "0" end)]
  | join("\u001f")' 2>/dev/null)

declare -A GH_NUM GH_NH
marker_less=0
if [ -n "$gh_tsv" ]; then
  while IFS=$'\037' read -r num marker nh; do
    if [ -z "$marker" ]; then marker_less=$((marker_less + 1)); continue; fi  # boundary 4
    GH_NUM[$marker]="$num"; GH_NH[$marker]="$nh"
  done <<< "$gh_tsv"
fi
[ "$marker_less" -gt 0 ] && log "ignored $marker_less open self-heal issue(s) without a marker (boundary 4)"

# --- mutating actions (DRY_RUN prints would-action instead of running) -------
created=0 reopened=0 closed=0 continuing=0 skipped_close=0 failures=0

act_create() { # <dedup_key> <title> <body>
  if dry; then echo "WOULD create: [self-heal] $1" >&2; created=$((created+1)); return; fi
  if gh issue create --repo "$REPO" --label "$LABEL" --title "$2" --body "$3" >/dev/null 2>&1; then
    created=$((created+1))
  else
    log "WARN: gh issue create failed for: $1 (retried next cycle)"; failures=$((failures+1))
  fi
}
act_reopen() { # <issue#> <observed_value>
  if dry; then echo "WOULD reopen: #$1 (flap)" >&2; reopened=$((reopened+1)); return; fi
  if gh issue reopen "$1" --repo "$REPO" \
       --comment "🔁 再発（flap）: observer が再び active を報告（$(ts)）。${2}" >/dev/null 2>&1; then
    reopened=$((reopened+1))
  else
    log "WARN: gh issue reopen failed for #$1 (retried next cycle)"; failures=$((failures+1))
  fi
}
act_close() { # <issue#>
  if dry; then echo "WOULD close: #$1" >&2; closed=$((closed+1)); return; fi
  if gh issue close "$1" --repo "$REPO" \
       --comment "✅ RESOLVED — observer が active を報告しなくなりました（$(ts)）。fleet 上でクリア済み。" >/dev/null 2>&1; then
    closed=$((closed+1))
  else
    log "WARN: gh issue close failed for #$1 (retried next cycle)"; failures=$((failures+1))
  fi
}

# --- Step 3a: NEW + CONTINUING (iterate ES open set) ------------------------
for k in "${!ES_DK[@]}"; do
  if [ -n "${GH_NUM[$k]:-}" ]; then
    continuing=$((continuing + 1)); continue
  fi
  dk="${ES_DK[$k]}"; obs="${ES_OBS[$k]}"
  # flap guard: reopen a <24h closed issue with the same marker instead of
  # creating a duplicate (read-only search; safe to run in DRY_RUN too).
  reopen_num=$(gh issue list --repo "$REPO" --label "$LABEL" --state closed \
      --search "self-heal-key:$k in:body" --limit 5 --json number,closedAt 2>/dev/null \
    | jq -r --argjson cut "$(date -u -d '24 hours ago' +%s)" \
        '[.[] | select((.closedAt|fromdateiso8601) > $cut)] | sort_by(.closedAt) | last | .number // empty' 2>/dev/null)
  if [ -n "$reopen_num" ]; then
    act_reopen "$reopen_num" "$obs"
  else
    body=$(cat <<EOF
**fleet self-heal alert**（CT111 observer 検知）

- **dedup_key**: \`$dk\`
- **source**: ${ES_SRC[$k]}   (uptime=monitor/TLS down, es-query=Process down)
- **severity**: ${ES_SEV[$k]}
- **host/service**: ${ES_HOST[$k]:-?} / ${ES_SVC[$k]:-?}
- **first_seen**: ${ES_FS[$k]}
- **observed**: $obs

---
解決は self-heal-resolve loop が担当します。自動修正できない場合は \`$NEEDS_HUMAN_LABEL\` を付けて停止します。

<!-- self-heal-key:$k -->
<!-- self-heal-source:${ES_SRC[$k]} -->
EOF
)
    act_create "$dk" "[self-heal] $dk" "$body"
  fi
done

# --- Step 3b: RESOLVED (iterate GH issues whose marker left the ES open set) -
for k in "${!GH_NUM[@]}"; do
  [ -n "${ES_DK[$k]:-}" ] && continue   # still open in ES -> CONTINUING (counted above)
  if [ "${GH_NH[$k]}" = "1" ]; then
    skipped_close=$((skipped_close + 1))   # boundary 5: leave needs-human open
    log "keep open #${GH_NUM[$k]} (marker=$k) — labelled $NEEDS_HUMAN_LABEL"
    continue
  fi
  act_close "${GH_NUM[$k]}"
done

# --- Step 4: summary ---------------------------------------------------------
prefix=""; dry && prefix="[DRY_RUN] "
extra=""
[ "$skipped_close" -gt 0 ] && extra+=" skipped_close=$skipped_close(needs-human)"
[ "$skipped_null"  -gt 0 ] && extra+=" skipped_null=$skipped_null"
[ "$failures"      -gt 0 ] && extra+=" failures=$failures"
if [ "$created" -eq 0 ] && [ "$reopened" -eq 0 ] && [ "$closed" -eq 0 ] && [ "$failures" -eq 0 ]; then
  echo "${prefix}self-heal-create: in sync — no changes (continuing=$continuing${extra})"
else
  echo "${prefix}self-heal-create: created=$created reopened=$reopened closed=$closed continuing=$continuing${extra}"
fi
exit 0
