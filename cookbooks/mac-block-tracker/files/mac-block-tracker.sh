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
#      mDNS (dig -p 5353 @<ip>), and pick the host whose `pi` is ann's
#      (fallback when no `pi` matches: model + locally administered MAC + no
#      DHCP host name, and only when exactly one host fits)
#   2. read that host's MAC from the neighbour table
#   3. compare it with the SSM slot that home-monitor builds filters 17/18 from
#   4. if it differs: rewrite filters 17/18 on the router, read them back,
#      store the MAC in the slot, and mail home-monitoring-alerts
#
# The router sees a fixed list of lines with one variable, the MAC, and the
# MAC must match ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ (and be unicast) before any
# line is sent. The admin password is read from SSM into a shell variable and
# written to the ssh pipe with the printf builtin; it never appears in argv or
# on disk.
#
# Usage: mac-block-tracker.sh            one pass
#        DRY_RUN=1 mac-block-tracker.sh  find and compare, change nothing
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
RTX_BANNER_WAIT="${RTX_BANNER_WAIT:-3}"
RTX_STEP_WAIT="${RTX_STEP_WAIT:-2}"
RTX_TIMEOUT="${RTX_TIMEOUT:-90}"
SCAN_PREFIX="${SCAN_PREFIX:-192.168.1}"
SCAN_RANGES="${SCAN_RANGES:-20-99 150-199}"
SCAN_PARALLEL="${SCAN_PARALLEL:-32}"
SNS_TOPIC_NAME="${SNS_TOPIC_NAME:-home-monitoring-alerts}"
STATE_DIR="${STATE_DIR:-/var/lib/mac-block-tracker}"
DRY_RUN="${DRY_RUN:-0}"
export AWS_REGION="${AWS_REGION:-ap-northeast-1}"
export AWS_PAGER=""

MAC_RE='^([0-9a-f]{2}:){5}[0-9a-f]{2}$'

log() { printf 'mac-block-tracker: %s\n' "$*"; }

# --- mDNS ---------------------------------------------------------------------

# Print "ip<TAB>pi<TAB>model" for a host that answers _airplay._tcp, nothing
# otherwise. Unicast queries to port 5353 are answered by mDNSResponder, so no
# multicast socket is needed.
probe_one() {
  local ip=$1 inst txt pi model
  inst=$(dig +time=1 +tries=1 +short -p 5353 "@$ip" _airplay._tcp.local PTR 2>/dev/null \
    | grep -v '^;' | head -n 1) || true
  [[ -n "$inst" ]] || return 0
  txt=$(dig +time=1 +tries=1 +short -p 5353 "@$ip" "$inst" TXT 2>/dev/null | grep -v '^;') || true
  pi=$(grep -o '"pi=[^"]*"' <<<"$txt" | head -n 1 | sed -e 's/^"pi=//' -e 's/"$//') || true
  model=$(grep -o '"model=[^"]*"' <<<"$txt" | head -n 1 | sed -e 's/^"model=//' -e 's/"$//') || true
  printf '%s\t%s\t%s\n' "$ip" "$pi" "$model"
}

if [[ "${1:-}" == "--probe" ]]; then
  probe_one "$2"
  exit 0
fi

: "${TRACKER_PI:?TRACKER_PI is required: the AirPlay pi of the tracked Mac}"

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

sns_topic_arn() {
  local account
  account=$(aws sts get-caller-identity --query Account --output text)
  printf 'arn:aws:sns:%s:%s:%s' "$AWS_REGION" "$account" "$SNS_TOPIC_NAME"
}

notify() { # subject body
  aws sns publish --topic-arn "$(sns_topic_arn)" --subject "$1" --message "$2" >/dev/null
}

# Report a failure once per distinct message, so a stuck condition does not
# mail every five minutes. A later success clears the record.
fail() {
  local msg=$1 last=""
  log "FAIL: $msg"
  [[ -f "$STATE_DIR/last-failure" ]] && last=$(cat "$STATE_DIR/last-failure")
  if [[ "$msg" != "$last" && "$DRY_RUN" != 1 ]]; then
    notify "mac-block-tracker: failed" "mac-block-tracker が失敗しました（ann の Mac の遮断が今の MAC に追従していない可能性があります）。

$msg

ログ: pro-dev で journalctl -u mac-block-tracker.service" || log "notify failed"
    printf '%s' "$msg" >"$STATE_DIR/last-failure"
  fi
  exit 1
}

# --- router -------------------------------------------------------------------

RTX_KEY_FILE=""
cleanup() { [[ -n "$RTX_KEY_FILE" ]] && rm -f "$RTX_KEY_FILE"; return 0; }
trap cleanup EXIT

# Fetch the router key into the runtime directory. Call it in the main shell,
# before any $(rtx_session ...): a key file created inside the command
# substitution would be invisible to the EXIT trap and outlive the run.
ensure_rtx_key() {
  [[ -n "$RTX_KEY_FILE" ]] && return 0
  RTX_KEY_FILE=$(mktemp "${RUNTIME_DIRECTORY:-/tmp}/rtx-key.XXXXXX")
  chmod 600 "$RTX_KEY_FILE"
  ssm_get_secret "$RTX_KEY_PARAM" >"$RTX_KEY_FILE"
}

# Send each argument as one line (CR-terminated) to an interactive RTX session
# and print the transcript with CRs stripped. The blank line after the banner
# absorbs the router's habit of dropping the first line typed.
rtx_session() {
  local user line
  user=$(ssm_get_secret "$RTX_USER_PARAM")
  {
    sleep "$RTX_BANNER_WAIT"
    printf '\r'
    sleep 1
    for line in "$@"; do
      printf '%s\r' "$line"
      sleep "$RTX_STEP_WAIT"
    done
    printf 'exit\r'
    sleep 1
    printf 'exit\r'
    sleep 1
  } 2>/dev/null | timeout "$RTX_TIMEOUT" ssh -tt -i "$RTX_KEY_FILE" \
    -o BatchMode=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$STATE_DIR/known_hosts" \
    -o PubkeyAcceptedKeyTypes=+ssh-rsa -o HostKeyAlgorithms=+ssh-rsa \
    "$user@$RTX_HOST" 2>&1 | tr -d '\r' || true
}

# The DHCP host name the router recorded for ip/mac ("" when none was sent).
dhcp_hostname() {
  local ip=$1 mac=$2 out line
  ensure_rtx_key
  out=$(rtx_session "console lines infinity" "show status dhcp summary")
  line=$(grep -F "$ip:" <<<"$out" | grep -F "$mac" | head -n 1) || true
  [[ -n "$line" ]] || { printf '%s' "?"; return 0; }
  if [[ "$line" == *", "* ]]; then
    printf '%s' "${line#*, }"
  fi
}

write_filters() { # mac -> 0 when the read-back shows both filters on mac
  local mac=$1 pw out src dst readback
  src="ethernet filter $FILTER_SRC reject-log $mac *"
  dst="ethernet filter $FILTER_DST reject-log * $mac"
  ensure_rtx_key
  pw=$(ssm_get_secret "$RTX_ADMIN_PARAM")
  out=$(rtx_session \
    "console lines infinity" \
    "administrator" \
    "$pw" \
    "$src" \
    "$dst" \
    "save" \
    'show config | grep "ethernet filter 1"')
  out="${out//"$pw"/[redacted]}"
  pw=""
  # Judge only what `show config` printed: everything after the echo of that
  # command, compared as whole fixed-string lines (the filter text ends in a
  # literal `*`). The echoes of the typed filter lines sit before it and carry
  # the "# " prompt anyway.
  readback=$(sed -n '/show config | grep/,$p' <<<"$out" | sed -e '1d' -e 's/[[:space:]]*$//')
  if grep -qxF -- "$src" <<<"$readback" && grep -qxF -- "$dst" <<<"$readback"; then
    return 0
  fi
  log "router transcript (read-back did not match):"
  printf '%s\n' "$out" | sed -e 's/^/  | /'
  return 1
}

# --- main ---------------------------------------------------------------------

mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
flock -n 9 || { log "another run holds the lock; skipping"; exit 0; }

self=$(readlink -f "$0")
scan=$(scan_targets | xargs -P "$SCAN_PARALLEL" -n 1 "$self" --probe)

method="pi"
mapfile -t hits < <(awk -F'\t' -v pi="$TRACKER_PI" '$2 == pi { print $1 }' <<<"$scan")

slot=$(ssm_get "$SLOT_PARAM") || fail "SSM $SLOT_PARAM を読めませんでした"
slot=$(lower <<<"$slot")

# Only a locally administered (private) MAC is ever written. While the Mac
# sleeps, a Bonjour Sleep Proxy (HomePod, Apple TV) can answer for its records
# and its IP, so the neighbour table may show the proxy's hardware MAC under a
# matching pi. ann's hardware MAC is blocked statically in home-monitor, so
# nothing is lost by refusing hardware MACs here.
candidates=()
for ip in "${hits[@]}"; do
  mac=$(mac_of "$ip")
  valid_mac "$mac" || { log "pi matched at $ip but its MAC is unknown ('$mac')"; continue; }
  if [[ "$mac" != "$slot" ]] && ! locally_administered "$mac"; then
    log "pi matched at $ip but $mac is a hardware MAC (sleep proxy or private address off); ignoring"
    continue
  fi
  candidates+=("$ip $mac")
done

if ((${#candidates[@]} == 0)); then
  # Fallback: the pi did not answer. Accept the single host that has the
  # model, a locally administered MAC and no DHCP host name — the footprint
  # ann's Mac showed on 2026-10-02 — and only when it is the only one.
  mapfile -t model_hits < <(awk -F'\t' -v m="$TRACKER_MODEL" '$3 == m { print $1 }' <<<"$scan")
  fallback=()
  for ip in "${model_hits[@]}"; do
    mac=$(mac_of "$ip")
    valid_mac "$mac" && locally_administered "$mac" || continue
    [[ "$mac" == "$slot" ]] && { log "ann's Mac not identified by pi, but $ip ($mac) is already the slot"; exit 0; }
    host=$(dhcp_hostname "$ip" "$mac")
    [[ -z "$host" ]] && fallback+=("$ip $mac")
  done
  if ((${#fallback[@]} == 1)); then
    method="fallback"
    candidates=("${fallback[0]}")
  elif ((${#fallback[@]} > 1)); then
    fail "pi が見つからず、予備条件に一致する端末が ${#fallback[@]} 台あります: ${fallback[*]}"
  else
    log "ann's Mac is not on the network (no pi match among $(grep -c . <<<"$scan" || true) AirPlay hosts)"
    exit 0
  fi
fi

for c in "${candidates[@]}"; do
  if [[ "${c#* }" == "$slot" ]]; then
    log "unchanged: ${c% *} has $slot (by $method)"
    rm -f "$STATE_DIR/last-failure"
    exit 0
  fi
done

((${#candidates[@]} == 1)) \
  || fail "ann の Mac が複数の MAC で見えていて、どれを遮断するか決められません: ${candidates[*]}"

ip=${candidates[0]% *}
mac=${candidates[0]#* }
valid_mac "$mac" || fail "不正な MAC です: '$mac'"

if [[ "$DRY_RUN" == 1 ]]; then
  log "DRY_RUN: would move filters $FILTER_SRC/$FILTER_DST from $slot to $mac ($ip, by $method)"
  exit 0
fi

log "ann's Mac is at $ip with $mac (by $method); slot holds $slot — rewriting filters $FILTER_SRC/$FILTER_DST"
write_filters "$mac" || fail "RTX のフィルタ $FILTER_SRC/$FILTER_DST を $mac に書き換えられませんでした（読み戻しが一致しません）。スロットは $slot のままです"
aws ssm put-parameter --name "$SLOT_PARAM" --value "$mac" --overwrite >/dev/null \
  || fail "RTX は $mac に書き換えましたが、SSM $SLOT_PARAM を更新できませんでした。次の terraform apply で $slot に戻ります"
rm -f "$STATE_DIR/last-failure"

note=""
[[ "$method" == fallback ]] && note="
※ AirPlay の pi が一致しなかったため、予備条件（機種 $TRACKER_MODEL・ランダム MAC・DHCP ホスト名なし）で判定しました。"

notify "mac-block-tracker: ann's Mac moved to $mac" "ann の Mac の MAC が変わったため、遮断対象を更新しました。

旧 MAC: $slot
新 MAC: $mac（$ip）
判定: $method$note
RTX: ethernet filter $FILTER_SRC / $FILTER_DST を書き換えて save 済み（読み戻しで一致を確認）
SSM: $SLOT_PARAM を更新済み

別の端末だった場合の戻し方:
1. pro-dev で止める: sudo systemctl disable --now mac-block-tracker.timer
2. スロットを戻す: aws ssm put-parameter --name $SLOT_PARAM --value $slot --overwrite --profile sh1admn --region $AWS_REGION
3. home-monitor で block_mac を targeted apply してフィルタ $FILTER_SRC/$FILTER_DST を戻す" || log "notify failed (the block itself is in place)"

log "done: filters $FILTER_SRC/$FILTER_DST and $SLOT_PARAM now hold $mac"
