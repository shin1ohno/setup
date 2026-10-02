#!/bin/bash
# mac-block-tracker — keep ann's Mac inside the rtx-hnd MAC block when macOS
# rotates its Private Wi-Fi Address.
#
# The block (home-monitor rtx-hnd.tf, block_mac) matches MAC addresses, and the
# Mac changes its MAC without any error on the router: the old filters simply
# stop matching. One pass of this script, run every 5 minutes by
# mac-block-tracker.timer:
#
#   1. ask every address in the DHCP pools for its AirPlay record over unicast
#      mDNS (dig -p 5353 @<ip>) and pick the host whose `pi` is ann's
#   2. read that host's MAC from the neighbour table; only a locally
#      administered (private) MAC is ever acted on
#   3. compare it with the SSM slot that home-monitor builds filters 17/18 from
#   4. when it differs on two consecutive runs: in one admin session, confirm
#      the ip/MAC pair in the router's DHCP table, confirm 17/18 currently are
#      a reject pair for a single MAC, rewrite them, read them back and save;
#      then confirm the saved config over SFTP, store the MAC in the slot and
#      mail home-monitoring-alerts
#   5. when it is unchanged, once an hour read the saved config over SFTP and
#      put 17/18 back on the slot MAC if something else moved them
#
# Guard rails: at most MAX_MOVES_PER_DAY rewrites a day; when the pi does not
# answer, a host with the same model is only reported, never written; a pass
# that sees no AirPlay host at all fails instead of looking like "Mac away".
#
# Secrets: the router key lives in the runtime directory for one run. The
# admin password is held in a shell variable and written to the ssh coprocess
# by the printf builtin, and only after the router has printed "Password:".
# The router host key is pinned (StrictHostKeyChecking=yes). Router output is
# never logged wholesale; failures name the step and show only filter lines.
#
# Usage: mac-block-tracker.sh            one pass
#        DRY_RUN=1 mac-block-tracker.sh  find and compare; no router, no SSM write, no mail
#        mac-block-tracker.sh --probe IP (internal) print "ip<TAB>pi<TAB>model"
set -euo pipefail

TRACKER_MODEL="${TRACKER_MODEL:-Mac15,12}"
SLOT_PARAM="${SLOT_PARAM:-/home-monitor/mac-blocks/ann/slot}"
FILTER_SRC="${FILTER_SRC:-17}"
FILTER_DST="${FILTER_DST:-18}"
RTX_HOST="${RTX_HOST:-192.168.1.253}"
RTX_KEY_PARAM="${RTX_KEY_PARAM:-/rtx-routers/hnd/ssh/private_key}"
RTX_USER_PARAM="${RTX_USER_PARAM:-/rtx-routers/hnd/sftp/username}"
RTX_ADMIN_PARAM="${RTX_ADMIN_PARAM:-/rtx-routers/hnd/admin_password}"
RTX_SAVED_CONFIG="${RTX_SAVED_CONFIG:-/system/config0}"
RTX_STEP_TIMEOUT="${RTX_STEP_TIMEOUT:-20}"
RTX_SAVE_TIMEOUT="${RTX_SAVE_TIMEOUT:-60}"
KNOWN_HOSTS="${KNOWN_HOSTS:-/etc/mac-block-tracker/known_hosts}"
SCAN_PREFIX="${SCAN_PREFIX:-192.168.1}"
SCAN_RANGES="${SCAN_RANGES:-20-99 150-199}"
SCAN_PARALLEL="${SCAN_PARALLEL:-32}"
SNS_TOPIC_NAME="${SNS_TOPIC_NAME:-home-monitoring-alerts}"
STATE_DIR="${STATE_DIR:-/var/lib/mac-block-tracker}"
MAX_MOVES_PER_DAY="${MAX_MOVES_PER_DAY:-3}"
VERIFY_INTERVAL="${VERIFY_INTERVAL:-3600}"
UNSEEN_ALERT_SECS="${UNSEEN_ALERT_SECS:-86400}"
NOTIFY_REPEAT_SECS="${NOTIFY_REPEAT_SECS:-21600}"
DRY_RUN="${DRY_RUN:-0}"
export AWS_REGION="${AWS_REGION:-ap-northeast-1}"
export AWS_PAGER=""

MAC_RE='^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
USER_PROMPT='> ?$'
ADMIN_PROMPT='# ?$'
PASSWORD_PROMPT='[Pp]assword: ?$'

log() { printf 'mac-block-tracker: %s\n' "$*"; }

# --- mDNS ---------------------------------------------------------------------

# Print "ip<TAB>pi<TAB>model" for a host that answers _airplay._tcp, nothing
# otherwise. The PTR answer comes from the LAN, so it must look like an
# instance name before it is passed on, and goes to dig as -q, never as a
# bare argument dig could read as an option.
probe_one() {
  local ip=$1 inst txt pi model
  inst=$(dig +time=1 +tries=1 +short -p 5353 "@$ip" -q _airplay._tcp.local -t PTR 2>/dev/null \
    | grep -v '^;' | head -n 1) || true
  [[ "$inst" =~ ^[^-+@[:space:]][^[:space:]]*\._airplay\._tcp\.local\.$ ]] || return 0
  txt=$(dig +time=1 +tries=1 +short -p 5353 "@$ip" -q "$inst" -t TXT 2>/dev/null | grep -v '^;') || true
  pi=$(grep -o '"pi=[^"]*"' <<<"$txt" | head -n 1 | sed -e 's/^"pi=//' -e 's/"$//') || true
  model=$(grep -o '"model=[^"]*"' <<<"$txt" | head -n 1 | sed -e 's/^"model=//' -e 's/"$//') || true
  printf '%s\t%s\t%s\n' "$ip" "$pi" "$model"
}

if [[ "${1:-}" == "--probe" ]]; then
  probe_one "$2"
  exit 0
fi

: "${TRACKER_PI:?TRACKER_PI is required: the AirPlay pi of the tracked Mac}"
[[ "$FILTER_SRC" =~ ^[0-9]+$ && "$FILTER_DST" =~ ^[0-9]+$ ]] || { log "FILTER_SRC/FILTER_DST must be numbers"; exit 2; }

scan_targets() {
  local range lo hi i
  for range in $SCAN_RANGES; do
    lo=${range%-*}
    hi=${range#*-}
    for ((i = lo; i <= hi; i++)); do
      printf '%s.%d\n' "$SCAN_PREFIX" "$i"
    done
  done
}

# --- helpers ------------------------------------------------------------------

lower() { tr '[:upper:]' '[:lower:]'; }
now() { date +%s; }

valid_mac() {
  [[ "$1" =~ $MAC_RE ]] || return 1
  # reject multicast/broadcast: least significant bit of the first octet
  (( (16#${1:0:2} & 1) == 0 ))
}

locally_administered() { (( (16#${1:0:2} & 2) != 0 )); }

mac_of() {
  ip neigh show "$1" 2>/dev/null \
    | awk '{for (i = 1; i < NF; i++) if ($i == "lladdr") { print $(i + 1); exit }}' \
    | lower
}

ssm_get() { aws ssm get-parameter --name "$1" --query Parameter.Value --output text; }
ssm_get_secret() { aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text; }

notify() { # subject body
  local account
  account=$(aws sts get-caller-identity --query Account --output text) || return 1
  aws sns publish --topic-arn "arn:aws:sns:$AWS_REGION:$account:$SNS_TOPIC_NAME" \
    --subject "$1" --message "$2" >/dev/null
}

# Mail once per distinct message per NOTIFY_REPEAT_SECS. The record is written
# only after SNS accepted the message, so an SNS outage does not swallow it.
notify_once() { # key subject body
  local f="$STATE_DIR/notified-$1" sig osig ots
  sig=$(printf '%s\n%s' "$2" "$3" | sha256sum | cut -c1-16)
  if [[ -f "$f" ]] && read -r osig ots <"$f" \
    && [[ "$osig" == "$sig" ]] && (( $(now) - ots < NOTIFY_REPEAT_SECS )); then
    return 0
  fi
  notify "$2" "$3" || return 1
  printf '%s %s\n' "$sig" "$(now)" >"$f"
}

HANDLED=0
fail() {
  log "FAIL: $1"
  HANDLED=1
  if [[ "$DRY_RUN" != 1 ]]; then
    notify_once failure "mac-block-tracker: failed" "mac-block-tracker が失敗しました（ann の Mac の遮断が今の MAC に追従していない可能性があります）。

$1

ログ: pro-dev で journalctl -u mac-block-tracker.service" || log "notify failed"
  fi
  exit 1
}

WORK=""
OWN_WORK=0
on_exit() {
  local rc=$?
  [[ -n "$WORK" && -f "$WORK/rtx-key" ]] && rm -f "$WORK/rtx-key"
  ((OWN_WORK == 1)) && rm -rf "$WORK"
  if ((rc != 0 && HANDLED == 0)) && [[ "$DRY_RUN" != 1 ]]; then
    notify_once failure "mac-block-tracker: failed" "mac-block-tracker が想定外の終了をしました（exit $rc）。ログ: pro-dev で journalctl -u mac-block-tracker.service" || true
  fi
  return "$rc"
}
trap on_exit EXIT

# --- router -------------------------------------------------------------------

RTX_USER=""
# Fetch the router user and key into the private work directory. Called in the
# main shell so the EXIT trap sees the key file.
ensure_rtx_access() {
  [[ -n "$RTX_USER" ]] && return 0
  RTX_USER=$(ssm_get_secret "$RTX_USER_PARAM") || return 1
  [[ "$RTX_USER" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || { log "unexpected router user name"; return 1; }
  ( umask 077 && ssm_get_secret "$RTX_KEY_PARAM" >"$WORK/rtx-key" ) || return 1
}

SSH_OPTS=(-i "" -o BatchMode=yes -o ConnectTimeout=10
  -o StrictHostKeyChecking=yes -o GlobalKnownHostsFile=/dev/null
  -o PubkeyAcceptedKeyTypes=+ssh-rsa -o HostKeyAlgorithms=+ssh-rsa)
ssh_opts() { SSH_OPTS[1]="$WORK/rtx-key"; printf '%s\0' "${SSH_OPTS[@]}" -o "UserKnownHostsFile=$KNOWN_HOSTS"; }

RTX_LAST=""
rtx_open() {
  local opts
  mapfile -d '' -t opts < <(ssh_opts)
  coproc RTX { exec ssh -tt "${opts[@]}" -l "$RTX_USER" -- "$RTX_HOST" 2>&1; }
  # bash unsets RTX_PID as soon as the coprocess exits; keep our own copy.
  RTX_CHILD=$RTX_PID
  RTX_LAST=""
  rtx_expect "$USER_PROMPT" "$RTX_STEP_TIMEOUT" || return 1
  # The router can drop the first line typed after the banner; a blank line
  # takes that slot and must come back as a fresh prompt.
  rtx_cmd "" "$USER_PROMPT"
}

# Read router output into RTX_LAST until it matches $1 or $2 seconds pass.
rtx_expect() {
  local re=$1 limit=$2 start=$SECONDS chunk rc
  while ((SECONDS - start < limit)); do
    [[ -n "${RTX[0]:-}" ]] || return 1
    chunk="" rc=0
    IFS= read -r -t 0.5 -N 4096 -u "${RTX[0]}" chunk || rc=$?
    RTX_LAST+=${chunk//$'\r'/}
    [[ "$RTX_LAST" =~ $re ]] && return 0
    ((rc == 0 || rc > 128)) || return 1 # EOF: the session ended
  done
  return 1
}

rtx_send() {
  [[ -n "${RTX[1]:-}" ]] || return 1 # the session already ended
  printf '%s\r' "$1" >&"${RTX[1]}"
}

rtx_cmd() { # line expect-regex [timeout]
  RTX_LAST=""
  rtx_send "$1"
  rtx_expect "$2" "${3:-$RTX_STEP_TIMEOUT}"
}

# What a command printed: drop the echoed command line and the final prompt.
rtx_body() { sed -e '1d' -e '$d' <<<"$RTX_LAST" | sed -e 's/[[:space:]]*$//' | grep -v '^$' || true; }

RTX_CHILD=""
rtx_close() {
  if [[ -n "$RTX_CHILD" ]]; then
    { [[ -n "${RTX[1]:-}" ]] && rtx_send "exit"; } 2>/dev/null || true
    sleep 1
    kill "$RTX_CHILD" 2>/dev/null || true
    wait "$RTX_CHILD" 2>/dev/null || true
    RTX_CHILD=""
  fi
  return 0
}

# Leave admin mode without saving anything that was not already saved.
rtx_leave_admin() {
  rtx_cmd "exit" "($USER_PROMPT|\\(Y/N\\) ?$)" || return 0
  if [[ "$RTX_LAST" =~ \(Y/N\)\ ?$ ]]; then rtx_cmd "N" "$USER_PROMPT" || true; fi
}

filter_line() { # text n -> the "ethernet filter n ..." line, trailing space trimmed
  sed -e 's/[[:space:]]*$//' <<<"$1" | grep -E "^ethernet filter $2 " | head -n 1 || true
}

# 17/18 must currently be "reject-log M *" / "reject-log * M" for one MAC M:
# anything else means the numbers were reused and must not be overwritten.
reject_pair_mac() { # text -> M, or nothing
  local s d ms md
  s=$(filter_line "$1" "$FILTER_SRC")
  d=$(filter_line "$1" "$FILTER_DST")
  [[ "$s" =~ ^ethernet\ filter\ $FILTER_SRC\ reject-log\ (([0-9a-f]{2}:){5}[0-9a-f]{2})\ \*$ ]] || return 0
  ms=${BASH_REMATCH[1]}
  [[ "$d" =~ ^ethernet\ filter\ $FILTER_DST\ reject-log\ \*\ (([0-9a-f]{2}:){5}[0-9a-f]{2})$ ]] || return 0
  md=${BASH_REMATCH[1]}
  [[ "$ms" == "$md" ]] && printf '%s' "$ms"
  return 0
}

saved_config() { # -> contents of the saved config over SFTP
  local opts
  mapfile -d '' -t opts < <(ssh_opts)
  rm -f "$WORK/saved-config"
  printf 'get %s %s\n' "$RTX_SAVED_CONFIG" "$WORK/saved-config" >"$WORK/sftp-batch"
  sftp -q -b "$WORK/sftp-batch" "${opts[@]}" "$RTX_USER@$RTX_HOST" >/dev/null 2>&1 || return 1
  cat "$WORK/saved-config"
}

WF_ERR=""
# Rewrite 17/18 to $1. $2 (optional) is the IP the MAC was seen at; when set,
# the router's DHCP table must show that pair. Sets WF_ERR on failure.
write_filters() {
  local mac=$1 ip=${2:-} pw src dst current saved
  src="ethernet filter $FILTER_SRC reject-log $mac *"
  dst="ethernet filter $FILTER_DST reject-log * $mac"
  ensure_rtx_access || { WF_ERR="SSM からルーターの接続情報を取れませんでした"; return 1; }
  pw=$(ssm_get_secret "$RTX_ADMIN_PARAM") || { WF_ERR="SSM から管理者パスワードを取れませんでした"; return 1; }
  rtx_open || { pw=""; WF_ERR="ルーターに SSH できませんでした（ホスト鍵の不一致を含む）"; rtx_close; return 1; }
  rtx_cmd "console lines infinity" "$USER_PROMPT" \
    || { pw=""; WF_ERR="console lines infinity が通りませんでした"; rtx_close; return 1; }
  rtx_cmd "administrator" "$PASSWORD_PROMPT" \
    || { pw=""; WF_ERR="administrator の後に Password: が出ませんでした（パスワードは送っていません）"; rtx_close; return 1; }
  RTX_LAST=""
  rtx_send "$pw"
  pw=""
  rtx_expect "$ADMIN_PROMPT" "$RTX_STEP_TIMEOUT" \
    || { WF_ERR="管理者モードに入れませんでした"; rtx_close; return 1; }

  if [[ -n "$ip" ]]; then
    rtx_cmd "show status dhcp summary" "$ADMIN_PROMPT" \
      || { WF_ERR="DHCP 表を読めませんでした"; rtx_leave_admin; rtx_close; return 1; }
    if ! rtx_body | grep -F "$ip:" | grep -qF "$mac"; then
      WF_ERR="ルーターの DHCP 表に $ip / $mac の組がありません（ARP の偽装を含め、近隣表の値を信用しません）"
      rtx_leave_admin; rtx_close; return 1
    fi
  fi

  rtx_cmd 'show config | grep "ethernet filter"' "$ADMIN_PROMPT" \
    || { WF_ERR="現在のフィルタを読めませんでした"; rtx_leave_admin; rtx_close; return 1; }
  current=$(reject_pair_mac "$(rtx_body)")
  if [[ -z "$current" ]]; then
    WF_ERR="フィルタ $FILTER_SRC/$FILTER_DST が 1 つの MAC の reject 対になっていないため書き換えません: $(filter_line "$(rtx_body)" "$FILTER_SRC") / $(filter_line "$(rtx_body)" "$FILTER_DST")"
    rtx_leave_admin; rtx_close; return 1
  fi

  local line
  for line in "$src" "$dst"; do
    rtx_cmd "$line" "$ADMIN_PROMPT" && [[ -z "$(rtx_body)" ]] \
      || { WF_ERR="ルーターが '$line' を受け付けませんでした: $(rtx_body | head -n 3)"; rtx_leave_admin; rtx_close; return 1; }
  done

  rtx_cmd 'show config | grep "ethernet filter"' "$ADMIN_PROMPT" \
    || { WF_ERR="書き換え後のフィルタを読めませんでした"; rtx_leave_admin; rtx_close; return 1; }
  if [[ "$(filter_line "$(rtx_body)" "$FILTER_SRC")" != "$src" || "$(filter_line "$(rtx_body)" "$FILTER_DST")" != "$dst" ]]; then
    WF_ERR="読み戻しが一致しません: $(filter_line "$(rtx_body)" "$FILTER_SRC") / $(filter_line "$(rtx_body)" "$FILTER_DST")"
    rtx_leave_admin; rtx_close; return 1
  fi

  rtx_cmd "save" "$ADMIN_PROMPT" "$RTX_SAVE_TIMEOUT" \
    || { WF_ERR="save が終わりませんでした"; rtx_leave_admin; rtx_close; return 1; }
  rtx_leave_admin
  rtx_close

  saved=$(saved_config) || { WF_ERR="保存済み設定（$RTX_SAVED_CONFIG）を SFTP で読めませんでした"; return 1; }
  if [[ "$(filter_line "$saved" "$FILTER_SRC")" != "$src" || "$(filter_line "$saved" "$FILTER_DST")" != "$dst" ]]; then
    WF_ERR="稼働中の設定は書き換わりましたが、保存済み設定に反映されていません"
    return 1
  fi
  return 0
}

# --- main ---------------------------------------------------------------------

mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
flock -n 9 || { log "another run holds the lock; skipping"; exit 0; }

if [[ -n "${RUNTIME_DIRECTORY:-}" ]]; then
  WORK=$RUNTIME_DIRECTORY
else
  WORK=$(mktemp -d)
  OWN_WORK=1
fi

slot=$(ssm_get "$SLOT_PARAM") || fail "SSM $SLOT_PARAM を読めませんでした"
valid_mac "$slot" || fail "SSM $SLOT_PARAM の値が MAC ではありません: '$slot'（home-monitor の plan も precondition で止まります）"

self=$(readlink -f "$0")
scan=$(scan_targets | xargs -P "$SCAN_PARALLEL" -n 1 "$self" --probe)
hosts=$(grep -c . <<<"$scan" || true)
((hosts > 0)) || fail "mDNS に応答した AirPlay 端末が 0 台でした（LAN か dig の不具合。ann の Mac が不在なだけなら HomePod などは応答します）"

mapfile -t hits < <(awk -F'\t' -v pi="$TRACKER_PI" '$2 == pi { print $1 }' <<<"$scan")

# A hardware MAC under the pi is a Bonjour Sleep Proxy answering for the
# sleeping Mac (or private addressing turned off — ann's hardware MAC is
# blocked statically in home-monitor). Neither is written.
candidates=()
for ip in "${hits[@]}"; do
  mac=$(mac_of "$ip")
  valid_mac "$mac" || { log "pi matched at $ip but its MAC is unknown"; continue; }
  if ! locally_administered "$mac"; then
    log "pi matched at $ip but $mac is a hardware MAC (sleep proxy or private address off); ignoring"
    continue
  fi
  candidates+=("$ip $mac")
done

if ((${#candidates[@]} == 0)); then
  last_seen=$(cat "$STATE_DIR/last-seen" 2>/dev/null || now)
  [[ -f "$STATE_DIR/last-seen" ]] || now >"$STATE_DIR/last-seen"
  if (( $(now) - last_seen > UNSEEN_ALERT_SECS )) && [[ "$DRY_RUN" != 1 ]]; then
    notify_once unseen "mac-block-tracker: ann's Mac not seen" "ann の Mac（pi $TRACKER_PI）を $(( ($(now) - last_seen) / 3600 )) 時間見ていません。電源が切れているだけなら問題ありません。AirPlay 受信を切った場合、MAC が変わっても追従できません。" \
      || log "notify failed"
  fi
  # The pi did not answer. A host with the same model and a private MAC is
  # reported, never written: a guest's MacBook Air would look the same.
  mapfile -t model_hits < <(awk -F'\t' -v m="$TRACKER_MODEL" '$3 == m { print $1 }' <<<"$scan")
  for ip in "${model_hits[@]}"; do
    mac=$(mac_of "$ip")
    valid_mac "$mac" && locally_administered "$mac" && [[ "$mac" != "$slot" ]] || continue
    log "pi not seen, but $ip ($mac) is a $TRACKER_MODEL with a private MAC; reporting only"
    [[ "$DRY_RUN" == 1 ]] || notify_once "model-$mac" "mac-block-tracker: unknown $TRACKER_MODEL at $ip" "ann の Mac の pi は見えませんでしたが、同じ機種（$TRACKER_MODEL）の端末が $ip（$mac）にいます。ann の Mac なら手で遮断してください:
aws ssm put-parameter --name $SLOT_PARAM --value $mac --overwrite --profile sh1admn --region $AWS_REGION
の後に home-monitor で block_mac を targeted apply します。" || log "notify failed"
  done
  log "ann's Mac is not on the network (no pi match among $hosts AirPlay hosts)"
  exit 0
fi

now >"$STATE_DIR/last-seen"
rm -f "$STATE_DIR/notified-unseen"

# More than one private MAC for the pi is someone else claiming it: refuse,
# even when one of them already holds the slot.
((${#candidates[@]} == 1)) \
  || fail "ann の pi が複数の端末から返っています（なりすましの可能性）: ${candidates[*]}"

ip=${candidates[0]% *}
mac=${candidates[0]#* }

if [[ "$mac" == "$slot" ]]; then
  rm -f "$STATE_DIR/pending"
  last_verify=$(cat "$STATE_DIR/last-verify" 2>/dev/null || echo 0)
  if [[ "$DRY_RUN" == 1 ]] || (( $(now) - last_verify < VERIFY_INTERVAL )); then
    log "unchanged: $ip has $slot"
    exit 0
  fi
  ensure_rtx_access || fail "SSM からルーターの接続情報を取れませんでした"
  saved=$(saved_config) || fail "保存済み設定（$RTX_SAVED_CONFIG）を SFTP で読めませんでした"
  on_router=$(reject_pair_mac "$saved")
  if [[ "$on_router" == "$slot" ]]; then
    now >"$STATE_DIR/last-verify"
    rm -f "$STATE_DIR/notified-failure"
    log "unchanged: $ip has $slot; router filters $FILTER_SRC/$FILTER_DST agree"
    exit 0
  fi
  [[ -n "$on_router" ]] || fail "ルーターのフィルタ $FILTER_SRC/$FILTER_DST が reject 対になっていません（home-monitor の apply 前か、番号が別用途）"
  log "drift: router filters hold $on_router but the slot holds $slot — putting the slot back"
  write_filters "$slot" || fail "ずれの修正に失敗しました: $WF_ERR"
  now >"$STATE_DIR/last-verify"
  notify "mac-block-tracker: router filters restored to $slot" "ルーターのフィルタ $FILTER_SRC/$FILTER_DST が $on_router になっていたため、スロットの値 $slot に戻しました（terraform apply の競合、手動変更、未保存のまま再起動などで起きます）。" \
    || { HANDLED=1; log "notify failed"; exit 1; }
  exit 0
fi

# A new private MAC: act only when the same MAC is seen on two consecutive
# runs, so a one-off answer does not move the block.
pending=$(cat "$STATE_DIR/pending" 2>/dev/null || true)
if [[ "$pending" != "$mac" ]]; then
  printf '%s' "$mac" >"$STATE_DIR/pending"
  log "first sighting of $mac at $ip (slot holds $slot); confirming on the next run"
  exit 0
fi

touch "$STATE_DIR/moves"
moves=$(awk -v cut=$(( $(now) - 86400 )) '$1 > cut' "$STATE_DIR/moves" | wc -l)
((moves < MAX_MOVES_PER_DAY)) \
  || fail "24 時間で $moves 回書き換えたため止めています（上限 $MAX_MOVES_PER_DAY）。最新の候補は $ip / $mac です"

if [[ "$DRY_RUN" == 1 ]]; then
  log "DRY_RUN: would move filters $FILTER_SRC/$FILTER_DST from $slot to $mac ($ip)"
  exit 0
fi

log "ann's Mac is at $ip with $mac; slot holds $slot — rewriting filters $FILTER_SRC/$FILTER_DST"
write_filters "$mac" "$ip" || fail "RTX のフィルタ $FILTER_SRC/$FILTER_DST を $mac に書き換えられませんでした: $WF_ERR（スロットは $slot のまま）"
now >>"$STATE_DIR/moves"
aws ssm put-parameter --name "$SLOT_PARAM" --value "$mac" --overwrite >/dev/null \
  || fail "RTX は $mac に書き換えましたが、SSM $SLOT_PARAM を更新できませんでした。次の terraform apply で $slot に戻ります"
rm -f "$STATE_DIR/pending" "$STATE_DIR/notified-failure"
now >"$STATE_DIR/last-verify"

notify "mac-block-tracker: ann's Mac moved to $mac" "ann の Mac の MAC が変わったため、遮断対象を更新しました。

旧 MAC: $slot
新 MAC: $mac（$ip、5 分おき 2 回の観測で一致）
RTX: ethernet filter $FILTER_SRC / $FILTER_DST を書き換えて save 済み（稼働中と保存済みの両方を読み戻して一致を確認）
SSM: $SLOT_PARAM を更新済み

別の端末だった場合の戻し方:
1. pro-dev で止める: sudo systemctl disable --now mac-block-tracker.timer
2. スロットを戻す: aws ssm put-parameter --name $SLOT_PARAM --value $slot --overwrite --profile sh1admn --region $AWS_REGION
3. home-monitor で block_mac を targeted apply してフィルタ $FILTER_SRC/$FILTER_DST を戻す" \
  || { HANDLED=1; log "notify failed (the block itself is in place)"; exit 1; }

log "done: filters $FILTER_SRC/$FILTER_DST and $SLOT_PARAM now hold $mac"
