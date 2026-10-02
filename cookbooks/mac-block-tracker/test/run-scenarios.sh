#!/bin/bash
# Hermetic scenarios for cookbooks/mac-block-tracker/files/mac-block-tracker.sh.
# Runs the PRODUCTION script unmodified with dig / ip / aws / ssh / sleep
# replaced by stand-ins on PATH that read fixtures from a throwaway tmpdir.
# No network, no router, no AWS.
#
# The ssh stand-in plays a tiny RTX: it echoes each line after a "# " prompt,
# remembers `ethernet filter N ...` lines when ROUTER_MODE=accept, prints them
# for `show config | grep ...`, and prints a fixture for
# `show status dhcp summary`.
#
# MBT_SCRIPT points the harness at another copy of the script — the positive
# control: against a copy with the hardware-MAC refusal removed, the
# sleep-proxy scenario MUST fail.
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

PI_ANN=422abf2b-9844-4e5a-a113-18c5a484d5e7
OLD=46:6c:01:c1:7a:81
NEW=2a:11:22:33:44:55
PW='s3cret-admin-pw'

# --- stand-ins ----------------------------------------------------------------
BIN=$T/bin
mkdir -p "$BIN"

cat >"$BIN/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF

cat >"$BIN/dig" <<'EOF'
#!/bin/bash
# dig +... -p 5353 @IP NAME TYPE
ip=""; name=""; type=""
for a in "$@"; do
  case "$a" in
    @*) ip=${a#@} ;;
    +*|-p|5353) ;;
    PTR|TXT) type=$a ;;
    *) name=$a ;;
  esac
done
f="$FIX/mdns/$ip"
[[ -f "$f.pi" ]] || { echo ";; communications error to $ip#5353: timed out"; exit 9; }
if [[ "$type" == PTR ]]; then
  echo "Test\\032Mac._airplay._tcp.local."
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
    cat "$f" ;;
  "ssm put-parameter")
    name=""; value=""
    while (($#)); do
      case "$1" in --name) name=$2 ;; --value) value=$2 ;; esac; shift
    done
    printf '%s' "$value" >"$FIX/ssm/${name//\//_}" ;;
  "sts get-caller-identity") echo 123456789012 ;;
  "sns publish")
    subject=""; while (($#)); do [[ "$1" == --subject ]] && subject=$2; shift; done
    echo "$subject" >>"$T/sns.log" ;;
  *) echo "unexpected aws call: $*" >&2; exit 1 ;;
esac
EOF

cat >"$BIN/ssh" <<'EOF'
#!/bin/bash
# A tiny RTX: stdin is CR-terminated lines.
echo "ssh $*" >>"$T/ssh-calls.log"
cfg="$T/router-config"
touch "$cfg"
while IFS= read -r -d $'\r' line; do
  printf '%s\n' "$line" >>"$T/ssh-input.log"
  printf '# %s\r\n' "$line"
  case "$line" in
    "ethernet filter "*)
      if [[ "${ROUTER_MODE:-accept}" == accept ]]; then
        n=$(cut -d' ' -f3 <<<"$line")
        grep -v "^ethernet filter $n " "$cfg" >"$cfg.new"; mv "$cfg.new" "$cfg"
        printf '%s \n' "$line" >>"$cfg"
      fi ;;
    "show config | grep"*) cat "$cfg" | sed 's/$/\r/' ;;
    "show status dhcp summary") cat "$FIX/dhcp-summary" ;;
    exit) break ;;
  esac
done
exit 0
EOF
chmod +x "$BIN"/*

# --- scenario plumbing --------------------------------------------------------
reset_fixture() {
  rm -rf "$T/fix" "$T"/*.log "$T/router-config" "$T/state"
  FIX=$T/fix
  mkdir -p "$FIX/mdns" "$FIX/neigh" "$FIX/ssm" "$T/state"
  printf '%s' "$OLD" >"$FIX/ssm/_home-monitor_mac-blocks_ann_slot"
  printf '%s' "$PW" >"$FIX/ssm/_rtx-routers_hnd_admin_password"
  printf '%s' "shin1ohno" >"$FIX/ssm/_rtx-routers_hnd_sftp_username"
  printf '%s\n' "-----BEGIN KEY-----" "x" "-----END KEY-----" >"$FIX/ssm/_rtx-routers_hnd_ssh_private_key"
  printf '  1:      192.168.1.60:  aa:aa:aa:aa:aa:aa, Mac\n' >"$FIX/dhcp-summary"
  export FIX
}

host() { # ip pi model mac
  printf '%s' "$2" >"$FIX/mdns/$1.pi"
  printf '%s' "$3" >"$FIX/mdns/$1.model"
  [[ -n "$4" ]] && printf '%s' "$4" >"$FIX/neigh/$1"
  return 0
}

run() { # env assignments... ; output in $T/out, status in $rc
  env PATH="$BIN:$PATH" T="$T" FIX="$FIX" TRACKER_PI="$PI_ANN" \
    SCAN_PREFIX=192.168.1 SCAN_RANGES="60-70" SCAN_PARALLEL=4 \
    STATE_DIR="$T/state" RUNTIME_DIRECTORY="$T/state" \
    "$@" bash "$SCRIPT" >"$T/out" 2>&1
  rc=$?
}

slot() { cat "$FIX/ssm/_home-monitor_mac-blocks_ann_slot"; }

# --- scenarios ----------------------------------------------------------------

echo "== 1. MAC unchanged: nothing is written"
reset_fixture
host 192.168.1.68 "$PI_ANN" Mac15,12 "$OLD"
run
assert_eq "exit 0" 0 "$rc"
assert_contains "logs unchanged" "unchanged" "$T/out"
assert_no_file "no router session" "$T/ssh-calls.log"
assert_no_file "no mail" "$T/sns.log"

echo "== 2. MAC rotated: router rewritten, read back, slot updated, mail sent"
reset_fixture
host 192.168.1.68 "$PI_ANN" Mac15,12 "$NEW"
run
assert_eq "exit 0" 0 "$rc"
assert_contains "sends administrator" "administrator" "$T/ssh-input.log"
assert_contains "sends filter 17" "ethernet filter 17 reject-log $NEW *" "$T/ssh-input.log"
assert_contains "sends filter 18" "ethernet filter 18 reject-log * $NEW" "$T/ssh-input.log"
assert_contains "saves" "save" "$T/ssh-input.log"
assert_eq "slot holds the new MAC" "$NEW" "$(slot)"
assert_contains "mail names the new MAC" "$NEW" "$T/sns.log"
assert_absent "password not in output" "$PW" "$T/out"
assert_eq "only allowed lines reach the router" "" \
  "$(grep -vxF -e '' -e 'console lines infinity' -e administrator -e "$PW" \
       -e "ethernet filter 17 reject-log $NEW *" -e "ethernet filter 18 reject-log * $NEW" \
       -e save -e 'show config | grep "ethernet filter 1"' -e exit "$T/ssh-input.log")"
assert_eq "key file removed" "" "$(ls "$T/state" | grep rtx-key || true)"

echo "== 3. Router does not take the change: no slot update, one mail per distinct failure"
reset_fixture
host 192.168.1.68 "$PI_ANN" Mac15,12 "$NEW"
run ROUTER_MODE=ignore
assert_eq "exit 1" 1 "$rc"
assert_eq "slot unchanged" "$OLD" "$(slot)"
assert_eq "one failure mail" 1 "$(grep -c failed "$T/sns.log")"
assert_absent "password not in transcript dump" "$PW" "$T/out"
run ROUTER_MODE=ignore
assert_eq "second identical failure is not mailed again" 1 "$(grep -c failed "$T/sns.log")"

echo "== 4. Sleep proxy answers with a hardware MAC: refused"
reset_fixture
host 192.168.1.68 "$PI_ANN" Mac15,12 "58:d3:49:35:21:7d"
run
assert_eq "exit 0" 0 "$rc"
assert_contains "logs the refusal" "hardware MAC" "$T/out"
assert_no_file "no router session" "$T/ssh-calls.log"
assert_eq "slot unchanged" "$OLD" "$(slot)"

echo "== 5. Mac not on the network: nothing happens"
reset_fixture
host 192.168.1.61 "d1e4d961-adad-4961-a725-d4aaa3b2b68f" AudioAccessory5,1 "58:d3:49:35:21:7d"
run
assert_eq "exit 0" 0 "$rc"
assert_contains "logs absence" "not on the network" "$T/out"
assert_no_file "no router session" "$T/ssh-calls.log"

echo "== 6. Fallback: pi changed, single Mac15,12 with a private MAC and no DHCP name"
reset_fixture
host 192.168.1.68 "ffffffff-0000-0000-0000-000000000000" Mac15,12 "$NEW"
printf '  1:      192.168.1.68:  %s\n' "$NEW" >"$FIX/dhcp-summary"
run
assert_eq "exit 0" 0 "$rc"
assert_eq "slot holds the new MAC" "$NEW" "$(slot)"
assert_contains "mail sent" "$NEW" "$T/sns.log"

echo "== 7. Fallback refused when the DHCP host name is present"
reset_fixture
host 192.168.1.68 "ffffffff-0000-0000-0000-000000000000" Mac15,12 "$NEW"
printf '  1:      192.168.1.68:  %s, Mac\n' "$NEW" >"$FIX/dhcp-summary"
run
assert_eq "exit 0" 0 "$rc"
assert_eq "slot unchanged" "$OLD" "$(slot)"
assert_absent "no filter write" "ethernet filter" "$T/ssh-input.log"

echo "== 8. Malformed MAC from the neighbour table never reaches the router"
reset_fixture
host 192.168.1.68 "$PI_ANN" Mac15,12 "2a:11:22:33:44:55;save"
run
assert_eq "exit 0" 0 "$rc"
assert_no_file "no router session" "$T/ssh-calls.log"
assert_eq "slot unchanged" "$OLD" "$(slot)"

echo "== 9. DRY_RUN changes nothing"
reset_fixture
host 192.168.1.68 "$PI_ANN" Mac15,12 "$NEW"
run DRY_RUN=1
assert_eq "exit 0" 0 "$rc"
assert_contains "reports the planned move" "DRY_RUN: would move" "$T/out"
assert_no_file "no router session" "$T/ssh-calls.log"
assert_no_file "no mail" "$T/sns.log"
assert_eq "slot unchanged" "$OLD" "$(slot)"

echo "== 10. Two private MACs for the same pi: refused"
reset_fixture
host 192.168.1.68 "$PI_ANN" Mac15,12 "$NEW"
host 192.168.1.69 "$PI_ANN" Mac15,12 "2a:99:88:77:66:55"
run
assert_eq "exit 1" 1 "$rc"
assert_no_file "no router session" "$T/ssh-calls.log"
assert_eq "slot unchanged" "$OLD" "$(slot)"

echo
echo "passed=$pass failed=$fail"
((fail == 0))
