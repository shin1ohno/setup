#!/usr/bin/env bash
#
# probe.sh — the ONLY way the linear-resolve worker observes production.
#
# Why this exists rather than letting the worker run the commands itself: the
# worker is `claude -p` with Bash. A tool deny-list is decorative against it —
# anything reachable with a credential in the environment is reachable with
# curl or ssh. So the credential lives HERE, the worker gets none, and the set
# of things it can observe is the set of subcommands below. Widening that set
# IS widening the loop's authority; add one per review, never a passthrough.
#
# Everything here is read-only. There is deliberately no subcommand that
# mutates a device, and no way to pass a free-form command through.
#
# Fails closed: SELF_HEAL/LINEAR probe credentials are supplied by the RUNNER,
# not by the worker's shell. The default profile name below does not exist
# until the dedicated read-only IAM principal is provisioned, so an
# unconfigured deployment errors instead of quietly borrowing an admin profile.

set -euo pipefail

AWS_PROFILE_="${LINEAR_PROBE_AWS_PROFILE:-linear-probe}"
AWS_REGION_="${LINEAR_PROBE_AWS_REGION:-ap-northeast-1}"
RTX_HOST="${LINEAR_PROBE_RTX_HOST:-192.168.1.253}"
RTX_KEY_SSM="${LINEAR_PROBE_RTX_KEY_SSM:-/rtx-routers/hnd/ssh/private_key}"
RTX_USER_SSM="${LINEAR_PROBE_RTX_USER_SSM:-/rtx-routers/hnd/sftp/username}"

die() { echo "probe: $*" >&2; exit 2; }

usage() {
  cat >&2 <<'USAGE'
usage: probe.sh <subcommand> [arg]

  rtx-dhcp-status          hnd の `show status dhcp`（全リース）
  lease-of <mac>           上の出力から 1 台分を抜き出す（mac は aa:bb:cc:dd:ee:ff）
  dns <name>               name の A レコードを解決する（*.home.local のみ）
  mac-is-random <mac>      MAC がローカル管理（ランダム化）かを判定する

読み取り専用です。任意コマンドの実行経路はありません。
USAGE
  exit 2
}

require_mac() {
  [[ "$1" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || die "not a MAC (lowercase aa:bb:cc:dd:ee:ff): $1"
}

require_name() {
  # home.local に閉じる。外部名を引かせる経路は作らない。
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.home\.local$ ]] || die "not a home.local name: $1"
}

rtx_dhcp_status() {
  local key user
  key=$(mktemp); chmod 600 "$key"
  # shellcheck disable=SC2064
  trap "rm -f '$key'" EXIT
  aws ssm get-parameter --name "$RTX_KEY_SSM" --with-decryption \
      --profile "$AWS_PROFILE_" --region "$AWS_REGION_" \
      --query Parameter.Value --output text > "$key" \
    || die "could not read the RTX key from SSM as profile '$AWS_PROFILE_'"
  user=$(aws ssm get-parameter --name "$RTX_USER_SSM" --with-decryption \
      --profile "$AWS_PROFILE_" --region "$AWS_REGION_" \
      --query Parameter.Value --output text) \
    || die "could not read the RTX username from SSM"

  # RTX の SSH は exec チャネルを拒否する（対話シェルのみ）。プロンプトを見てから
  # 書かないと入力が捨てられ、ページャの一時停止はスペースで送る必要がある。
  KEY="$key" USER_="$user" HOST="$RTX_HOST" python3 - <<'PY'
import os, pty, select, sys, time
key, user, host = os.environ["KEY"], os.environ["USER_"], os.environ["HOST"]
cmd = ["ssh","-4","-tt","-i",key,"-o","StrictHostKeyChecking=no",
       "-o","BatchMode=yes","-o","ConnectTimeout=6",f"{user}@{host}"]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd); os._exit(1)
buf, sent = b"", 0
steps = [b"show status dhcp\r", b"exit\r"]
deadline = time.time() + 60
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 1.0)
    if r:
        try: chunk = os.read(fd, 4096)
        except OSError: break
        if not chunk: break
        buf += chunk
    tail = buf[-200:]
    if b"---" in tail and "つづく".encode() in tail:
        os.write(fd, b" "); buf = buf[:-1]; continue
    if b"> " in tail and sent < len(steps):
        time.sleep(0.4); os.write(fd, steps[sent]); sent += 1
        buf += b"\n"; time.sleep(0.6)
sys.stdout.write(buf.decode("utf-8", "replace").replace("\r", ""))
PY
}

case "${1:-}" in
  rtx-dhcp-status)
    [ $# -eq 1 ] || usage
    rtx_dhcp_status
    ;;
  lease-of)
    [ $# -eq 2 ] || usage
    require_mac "$2"
    spaced=${2//:/ }
    rtx_dhcp_status | grep -B2 -A2 -e "$2" -e "$spaced" || echo "(no lease for $2)"
    ;;
  dns)
    [ $# -eq 2 ] || usage
    require_name "$2"
    getent ahostsv4 "$2" | awk '{print $1}' | sort -u
    ;;
  mac-is-random)
    [ $# -eq 2 ] || usage
    require_mac "$2"
    first=$((16#${2%%:*}))
    if [ $((first & 2)) -ne 0 ]; then
      echo "locally-administered — randomized. DO NOT bind (see air-private-wifi-mac-dhcp-trap)."
    else
      echo "globally-administered — a real hardware address. Safe to bind."
    fi
    ;;
  *) usage ;;
esac
