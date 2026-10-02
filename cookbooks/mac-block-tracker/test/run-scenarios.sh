#!/bin/bash
# Hermetic scenarios for cookbooks/mac-block-tracker/files/mac-block-tracker.sh.
# Runs the PRODUCTION script unmodified with dig / ip / aws / ssh / sftp /
# sleep replaced by stand-ins on PATH that read fixtures from a throwaway
# tmpdir. No network, no router, no AWS.
#
# The ssh stand-in is a small RTX: it prints "> " in user mode and "# " in
# admin mode, asks "Password: " after `administrator` and only enters admin
# mode for the right password, accepts `ethernet filter` lines only in admin
# mode, keeps a running and a saved config (`save` copies one to the other),
# asks "(Y/N)" when leaving admin mode with unsaved changes, and prints the
# DHCP table fixture. The sftp stand-in serves the saved config.
#
# MBT_SCRIPT points the harness at another copy of the script (made
# executable) — the positive control: against a copy whose hardware-MAC
# refusal is removed, the sleep-proxy scenario MUST fail.
#
# Exit 0 when every assertion passes. One PASS/FAIL line per assertion.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="${MBT_SCRIPT:-$HERE/../files/mac-block-tracker.sh}"

T=$(mktemp -d "${TMPDIR:-/tmp}/mac-block-tracker-test.XXXXXX")
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS  $*"; }
bad() { fail=$((fail+1)); echo "FAIL  $*"; }
assert_eq()       { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }
assert_contains() { if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1 ('$2' not in $(basename "$3"))"; fi; }
assert_absent()   { if grep -qF -- "$2" "$3" 2>/dev/null; then bad "$1 ('$2' found in $(basename "$3"))"; else ok "$1"; fi; }
assert_no_file()  { if [[ -s "$2" ]]; then bad "$1 ($(basename "$2") is not empty)"; else ok "$1"; fi; }
assert_no_key()   { if find "$T/run" "$T/tmp" -name 'rtx-key*' 2>/dev/null | grep -q .; then bad "$1 (router key left behind)"; else ok "$1"; fi; }

PI_ANN=422abf2b-9844-4e5a-a113-18c5a484d5e7
OLD=46:6c:01:c1:7a:81
NEW=2a:11:22:33:44:55
PW='s3cret?admin-pw'

# --- stand-ins ----------------------------------------------------------------
BIN=$T/bin
mkdir -p "$BIN"

printf '#!/bin/bash\nexit 0\n' >"$BIN/sleep"

cat >"$BIN/dig" <<'EOF'
#!/bin/bash
# dig +... -p 5353 @IP -q NAME -t TYPE
ip=""; type=""
while (($#)); do
  case "$1" in
    @*) ip=${1#@} ;;
    -t) type=$2; shift ;;
    -q|-p) shift ;;
  esac
  shift
done
f="$FIX/mdns/$ip"
[[ -f "$f.pi" ]] || { echo ";; communications error to $ip#5353: timed out"; exit 9; }
if [[ "$type" == PTR ]]; then
  if [[ -f "$f.ptr" ]]; then cat "$f.ptr"; else echo "Test\\032Mac._airplay._tcp.local."; fi
else
  printf '"deviceid=AA:BB:CC:DD:EE:FF" "model=%s" "pi=%s"\n' "$(cat "$f.model")" "$(cat "$f.pi")"
fi
EOF

cat >"$BIN/ip" <<'EOF'
#!/bin/bash
# ip neigh show IP
f="$FIX/neigh/$3"
[[ -f "$f" ]] && printf '%s dev eth0 lladdr %s REACHABLE\n' "$3" "$(cat "$f")"
exit 0
EOF

cat >"$BIN/aws" <<'EOF'
#!/bin/bash
echo "aws $*" >>"$T/aws.log"
case "$1 $2" in
  "ssm get-parameter")
    name=""; while (($#)); do [[ "$1" == --name ]] && name=$2; shift; done
    f="$FIX/ssm/${name//\//_}"
    [[ -f "$f" ]] || { echo "ParameterNotFound" >&2; exit 254; }
    cat "$f"; echo ;;
  "ssm put-parameter")
    name=""; value=""
    while (($#)); do
      case "$1" in --name) name=$2 ;; --value) value=$2 ;; esac; shift
    done
    printf '%s' "$value" >"$FIX/ssm/${name//\//_}" ;;
  "sts get-caller-identity") echo 123456789012 ;;
  "sns publish")
    subject=""; while (($#)); do [[ "$1" == --subject ]] && subject=$2; shift; done
    [[ -n "${SNS_DOWN:-}" ]] && exit 1
    echo "$subject" >>"$T/sns.log" ;;
  *) echo "unexpected aws call: $*" >&2; exit 1 ;;
esac
EOF

cat >"$BIN/ssh" <<'EOF'
#!/bin/bash
# A small RTX on stdin/stdout.
echo "ssh $*" >>"$T/ssh-calls.log"
run=$T/router-running; saved=$T/router-saved
mode=user; want_pw=0; want_yn=0
prompt() { if [[ $mode == admin ]]; then printf '# '; else printf '> '; fi; }
printf 'RTX1210 Rev.14.01.42\r\n'
prompt
while IFS= read -r -d $'\r' line; do
  printf '%s\n' "$line" >>"$T/ssh-input.log"
  if ((want_pw)); then
    want_pw=0
    printf '\r\n'
    if [[ "$line" == "$ROUTER_PW" ]]; then mode=admin; else printf 'Password incorrect\r\n'; fi
    prompt; continue
  fi
  printf '%s\r\n' "$line"
  if ((want_yn)); then
    want_yn=0; mode=user
    [[ "$line" == Y ]] && cp "$run" "$saved"
    prompt; continue
  fi
  case "$line" in
    administrator)
      if [[ -n "${ROUTER_NO_PW_PROMPT:-}" ]]; then prompt; continue; fi
      printf 'Password: '; want_pw=1; continue ;;
    "ethernet filter "*)
      if [[ $mode != admin ]]; then printf 'Error: Permission denied\r\n'
      elif [[ "${ROUTER_MODE:-accept}" == accept ]]; then
        n=$(cut -d' ' -f3 <<<"$line")
        grep -v "^ethernet filter $n " "$run" >"$run.new"; mv "$run.new" "$run"
        printf '%s \n' "$line" >>"$run"
      fi ;;
    "show config | grep"*)
      [[ $mode == admin ]] && grep '^ethernet filter' "$run" | sed 's/$/\r/' ;;
    "show status dhcp summary") sed 's/$/\r/' "$FIX/dhcp-summary" ;;
    save)
      if [[ $mode == admin ]]; then
        [[ -z "${ROUTER_SAVE_BROKEN:-}" ]] && cp "$run" "$saved"
        printf 'Saving ... CONFIG0 Done\r\n'
      fi ;;
    exit)
      if [[ $mode == admin ]]; then
        if ! cmp -s "$run" "$saved"; then printf 'Save new configuration ? (Y/N) '; want_yn=1; continue; fi
        mode=user
      else
        exit 0
      fi ;;
  esac
  prompt
done
exit 0
EOF

cat >"$BIN/sftp" <<'EOF'
#!/bin/bash
echo "sftp $*" >>"$T/sftp-calls.log"
[[ -n "${SFTP_DOWN:-}" ]] && exit 1
batch=""; while (($#)); do [[ "$1" == -b ]] && batch=$2; shift; done
read -r _ src dst <"$batch"
[[ "$src" == /system/config0 ]] || exit 1
cp "$T/router-saved" "$dst"
EOF
chmod +x "$BIN"/*

# --- scenario plumbing --------------------------------------------------------
router_config() { # mac-for-17/18 -> both running and saved
  {
    echo "ethernet filter 1 reject-log bc:5c:17:05:59:3a *"
    echo "ethernet filter 15 reject-log $OLD *"
    echo "ethernet filter 16 reject-log * $OLD"
    echo "ethernet filter 17 reject-log $1 *"
    echo "ethernet filter 18 reject-log * $1"
    echo "ethernet filter 100 pass-nolog * *"
  } >"$T/router-running"
  cp "$T/router-running" "$T/router-saved"
}

reset_fixture() {
  rm -rf "$T/fix" "$T"/*.log "$T/state" "$T/run" "$T/tmp" "$T"/router-*
  FIX=$T/fix
  mkdir -p "$FIX/mdns" "$FIX/neigh" "$FIX/ssm" "$T/state" "$T/run" "$T/tmp"
  printf '%s' "$OLD" >"$FIX/ssm/_home-monitor_mac-blocks_ann_slot"
  printf '%s' "$PW" >"$FIX/ssm/_rtx-routers_hnd_admin_password"
  printf '%s' "shin1ohno" >"$FIX/ssm/_rtx-routers_hnd_sftp_username"
  printf '%s\n' "-----BEGIN KEY-----" "x" "-----END KEY-----" >"$FIX/ssm/_rtx-routers_hnd_ssh_private_key"
  : >"$FIX/dhcp-summary"
  router_config "$OLD"
  # an always-on AirPlay host, so "nobody answered" is not the default
  host 192.168.1.61 "d1e4d961-adad-4961-a725-d4aaa3b2b68f" AudioAccessory5,1 "58:d3:49:35:21:7d"
  date +%s >"$T/state/last-verify"
  export FIX
}

host() { # ip pi model [mac]
  printf '%s' "$2" >"$FIX/mdns/$1.pi"
  printf '%s' "$3" >"$FIX/mdns/$1.model"
  [[ -n "${4:-}" ]] && printf '%s' "$4" >"$FIX/neigh/$1"
  return 0
}

dhcp() { printf '  %d:      %s:  %s%s\n' "$RANDOM" "$1" "$2" "${3:+, $3}" >>"$FIX/dhcp-summary"; }

run() { # env assignments...
  env PATH="$BIN:$PATH" T="$T" FIX="$FIX" TRACKER_PI="$PI_ANN" ROUTER_PW="$PW" \
    SCAN_PREFIX=192.168.1 SCAN_RANGES="60-70" SCAN_PARALLEL=4 \
    STATE_DIR="$T/state" RUNTIME_DIRECTORY="$T/run" TMPDIR="$T/tmp" KNOWN_HOSTS="$T/known_hosts" \
    RTX_STEP_TIMEOUT=5 RTX_SAVE_TIMEOUT=5 \
    "$@" bash "$SCRIPT" >"$T/out" 2>&1
  rc=$?
}

slot() { cat "$FIX/ssm/_home-monitor_mac-blocks_ann_slot"; }
saved_17() { grep '^ethernet filter 17 ' "$T/router-saved" | sed 's/[[:space:]]*$//'; }

# --- scenarios ----------------------------------------------------------------

echo "== 1. MAC unchanged, verification not due: no router contact"
reset_fixture
host 192.168.1.68 "$PI_ANN" Mac15,12 "$OLD"
run
assert_eq "exit 0" 0 "$rc"
assert_contains "logs unchanged" "unchanged" "$T/out"
assert_no_file "no ssh" "$T/ssh-calls.log"
assert_no_file "no sftp" "$T/sftp-calls.log"
assert_no_file "no mail" "$T/sns.log"

echo "== 2. MAC unchanged, hourly verification: router agrees over SFTP"
reset_fixture
host 192.168.1.68 "$PI_ANN" Mac15,12 "$OLD"
echo 0 >"$T/state/last-verify"
run
assert_eq "exit 0" 0 "$rc"
assert_contains "reads the saved config" "sftp" "$T/sftp-calls.log"
assert_no_file "no ssh" "$T/ssh-calls.log"
assert_contains "logs agreement" "agree" "$T/out"
assert_no_key "key removed"

echo "== 3. Drift: the router holds another MAC on 17/18, the slot wins"
reset_fixture
host 192.168.1.68 "$PI_ANN" Mac15,12 "$OLD"
router_config "2a:00:00:00:00:01"
echo 0 >"$T/state/last-verify"
run
assert_eq "exit 0" 0 "$rc"
assert_eq "saved config back on the slot" "ethernet filter 17 reject-log $OLD *" "$(saved_17)"
assert_contains "mail says restored" "restored" "$T/sns.log"
assert_no_key "key removed"

echo "== 4. Rotation: first sighting only records it"
reset_fixture
host 192.168.1.68 "$PI_ANN" Mac15,12 "$NEW"
dhcp 192.168.1.68 "$NEW"
run
assert_eq "exit 0" 0 "$rc"
assert_contains "logs first sighting" "first sighting" "$T/out"
assert_no_file "no ssh" "$T/ssh-calls.log"
assert_eq "slot unchanged" "$OLD" "$(slot)"

echo "== 5. Rotation: second sighting rewrites, saves, verifies and mails"
run
assert_eq "exit 0" 0 "$rc"
assert_eq "saved config has the new MAC" "ethernet filter 17 reject-log $NEW *" "$(saved_17)"
assert_eq "slot holds the new MAC" "$NEW" "$(slot)"
assert_contains "mail names the new MAC" "$NEW" "$T/sns.log"
assert_contains "host key is pinned" "StrictHostKeyChecking=yes" "$T/ssh-calls.log"
assert_contains "pinned known_hosts file" "UserKnownHostsFile=$T/known_hosts" "$T/ssh-calls.log"
assert_eq "administrator precedes the password, which precedes filter lines" \
  "administrator|$PW|ethernet filter 17 reject-log $NEW *|ethernet filter 18 reject-log * $NEW" \
  "$(grep -xF -e administrator -e "$PW" -e "ethernet filter 17 reject-log $NEW *" -e "ethernet filter 18 reject-log * $NEW" "$T/ssh-input.log" | paste -sd'|')"
assert_absent "password not in output" "$PW" "$T/out"
assert_absent "password fragment not in output" "s3cret" "$T/out"
assert_no_key "key removed"

echo "== 6. Router never asks for the password: it is not sent"
reset_fixture
host 192.168.1.68 "$PI_ANN" Mac15,12 "$NEW"
dhcp 192.168.1.68 "$NEW"
printf '%s' "$NEW" >"$T/state/pending"
run ROUTER_NO_PW_PROMPT=1
assert_eq "exit 1" 1 "$rc"
assert_absent "password never typed" "$PW" "$T/ssh-input.log"
assert_absent "no filter line typed" "ethernet filter" "$T/ssh-input.log"
assert_eq "slot unchanged" "$OLD" "$(slot)"
assert_eq "one failure mail" 1 "$(grep -c failed "$T/sns.log")"
run ROUTER_NO_PW_PROMPT=1
assert_eq "the same failure is not mailed again" 1 "$(grep -c failed "$T/sns.log")"

echo "== 7. Router ignores the filter lines: read-back fails, nothing saved"
reset_fixture
host 192.168.1.68 "$PI_ANN" Mac15,12 "$NEW"
dhcp 192.168.1.68 "$NEW"
printf '%s' "$NEW" >"$T/state/pending"
run ROUTER_MODE=ignore
assert_eq "exit 1" 1 "$rc"
assert_contains "names the read-back" "読み戻しが一致しません" "$T/out"
assert_eq "slot unchanged" "$OLD" "$(slot)"
assert_no_key "key removed"

echo "== 8. save does not persist: caught by the SFTP check"
reset_fixture
host 192.168.1.68 "$PI_ANN" Mac15,12 "$NEW"
dhcp 192.168.1.68 "$NEW"
printf '%s' "$NEW" >"$T/state/pending"
run ROUTER_SAVE_BROKEN=1
assert_eq "exit 1" 1 "$rc"
assert_contains "names the saved config" "保存済み設定に反映されていません" "$T/out"
assert_eq "slot unchanged" "$OLD" "$(slot)"

echo "== 9. DHCP table does not show the ip/MAC pair: no write"
reset_fixture
host 192.168.1.68 "$PI_ANN" Mac15,12 "$NEW"
dhcp 192.168.1.68 "2a:99:99:99:99:99"
printf '%s' "$NEW" >"$T/state/pending"
run
assert_eq "exit 1" 1 "$rc"
assert_absent "no filter line typed" "ethernet filter 1" "$T/ssh-input.log"
assert_eq "router untouched" "ethernet filter 17 reject-log $OLD *" "$(saved_17)"

echo "== 10. 17/18 are not a reject pair (numbers reused): no overwrite"
reset_fixture
host 192.168.1.68 "$PI_ANN" Mac15,12 "$NEW"
dhcp 192.168.1.68 "$NEW"
printf '%s' "$NEW" >"$T/state/pending"
sed -i 's/^ethernet filter 17 .*/ethernet filter 17 pass-log * */' "$T/router-running" "$T/router-saved"
run
assert_eq "exit 1" 1 "$rc"
assert_absent "no filter line typed" "ethernet filter 17 reject-log $NEW" "$T/ssh-input.log"

echo "== 11. Sleep proxy answers with a hardware MAC: refused"
reset_fixture
host 192.168.1.68 "$PI_ANN" Mac15,12 "58:d3:49:35:21:7d"
# already seen once and present in the DHCP table, so only the refusal
# itself stands between this MAC and the router
dhcp 192.168.1.68 "58:d3:49:35:21:7d"
printf '%s' "58:d3:49:35:21:7d" >"$T/state/pending"
run
assert_eq "exit 0" 0 "$rc"
assert_contains "logs the refusal" "hardware MAC" "$T/out"
assert_no_file "no ssh" "$T/ssh-calls.log"
assert_eq "slot unchanged" "$OLD" "$(slot)"

echo "== 12. A decoy claims the pi while the real Mac moved: refused, mailed"
reset_fixture
host 192.168.1.68 "$PI_ANN" Mac15,12 "$NEW"
host 192.168.1.69 "$PI_ANN" Mac15,12 "$OLD"
run
assert_eq "exit 1" 1 "$rc"
assert_contains "names the impersonation" "なりすまし" "$T/out"
assert_no_file "no ssh" "$T/ssh-calls.log"
assert_contains "mailed" "failed" "$T/sns.log"

echo "== 13. Same model, other pi: reported, never written (no router contact)"
reset_fixture
host 192.168.1.68 "ffffffff-0000-0000-0000-000000000000" Mac15,12 "$NEW"
TMP_RUN=1
run RUNTIME_DIRECTORY=
assert_eq "exit 0" 0 "$rc"
assert_contains "mail reports the host" "unknown Mac15,12" "$T/sns.log"
assert_no_file "no ssh" "$T/ssh-calls.log"
assert_eq "slot unchanged" "$OLD" "$(slot)"
assert_eq "own work directory removed" "" "$(ls -A "$T/tmp")"

echo "== 14. Nobody answers mDNS: a failure, not 'Mac away'"
reset_fixture
rm -f "$FIX/mdns/"*
run
assert_eq "exit 1" 1 "$rc"
assert_contains "names the scan" "0 台" "$T/out"

echo "== 15. Daily move limit"
reset_fixture
host 192.168.1.68 "$PI_ANN" Mac15,12 "$NEW"
dhcp 192.168.1.68 "$NEW"
printf '%s' "$NEW" >"$T/state/pending"
for _ in 1 2 3; do date +%s >>"$T/state/moves"; done
run
assert_eq "exit 1" 1 "$rc"
assert_no_file "no ssh" "$T/ssh-calls.log"

echo "== 16. A PTR answer shaped like a dig option is not followed"
reset_fixture
host 192.168.1.68 "$PI_ANN" Mac15,12 "$NEW"
echo "-f/etc/passwd._airplay._tcp.local." >"$FIX/mdns/192.168.1.68.ptr"
run
assert_eq "exit 0" 0 "$rc"
assert_contains "treated as absent" "not on the network" "$T/out"

echo "== 17. A malformed slot value fails loudly"
reset_fixture
printf 'FF:FF:FF:FF:FF:FF' >"$FIX/ssm/_home-monitor_mac-blocks_ann_slot"
host 192.168.1.68 "$PI_ANN" Mac15,12 "$OLD"
run
assert_eq "exit 1" 1 "$rc"
assert_contains "names the slot" "MAC ではありません" "$T/out"

echo "== 18. SNS down: the failure is mailed once SNS is back"
reset_fixture
rm -f "$FIX/mdns/"*
run SNS_DOWN=1
assert_eq "exit 1" 1 "$rc"
run
assert_eq "mailed after recovery" 1 "$(grep -c failed "$T/sns.log")"

echo "== 19. DRY_RUN: no router, no SSM write, no mail"
reset_fixture
host 192.168.1.68 "$PI_ANN" Mac15,12 "$NEW"
dhcp 192.168.1.68 "$NEW"
printf '%s' "$NEW" >"$T/state/pending"
run DRY_RUN=1
assert_eq "exit 0" 0 "$rc"
assert_contains "reports the planned move" "DRY_RUN: would move" "$T/out"
assert_no_file "no ssh" "$T/ssh-calls.log"
assert_no_file "no mail" "$T/sns.log"
assert_eq "slot unchanged" "$OLD" "$(slot)"

echo
echo "passed=$pass failed=$fail"
((fail == 0))
