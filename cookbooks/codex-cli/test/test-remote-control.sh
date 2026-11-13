#!/usr/bin/env bash
# Regression suite for codex-cli::remote_control.
#
#   1. files/codex-remote-control-guard.sh against a fake /proc, a stateful
#      `systemctl` stand-in, `kill` and `codex`: process classification by
#      exact argv fields and cgroup, eviction of daemons outside the unit, the
#      watchdog's decisions (including the owner's sentinel), environment
#      scrubbing, the bounded DNS wait and the updater setting merge.
#   2. remote_control.rb rendered through a stub DSL (render-remote-control.rb)
#      in a fixture HOME, running the recipe's real command strings: no user
#      bus -> WARN + exit 0, first activation (one restart, timer before a
#      non-blocking service start), a failing start, the converged state ->
#      nothing runs, sentinel -> disable and never enable, the root apply.
#
# Override GUARD / RECIPE to point the suite at another copy (that is how a
# deliberately broken copy is shown to fail).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
GUARD=${GUARD:-$here/../files/codex-remote-control-guard.sh}
RECIPE=${RECIPE:-$here/../remote_control.rb}
RENDER=$here/render-remote-control.rb
UNIT=codex-remote-control.service
TIMER=codex-remote-control-watch.timer

fails=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# Short path: the fake user-bus socket must fit in sun_path (108 bytes).
work=$(mktemp -d /tmp/crc.XXXXXX)
trap 'rm -rf "$work"' EXIT

# --- fixture helpers ---------------------------------------------------------

stubs=$work/stubs
mkdir -p "$stubs"
calls=$work/calls.log
export CALLS=$calls FAKE_STATE_DIR=$work/state FAKE_UNIT_DIR=$work/none
# A stateful `systemctl --user`: enable/disable maintain the .wants symlinks
# in FAKE_UNIT_DIR, restart/disable --now maintain the active set, and a
# blocking restart of the service fails when FAKE_FAIL_START is set (a
# --no-block one succeeds, as systemd's does: the job is only queued).
cat > "$stubs/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "$CALLS"
[ "$1" = --user ] && shift
active=$FAKE_STATE_DIR/active
mkdir -p "$active"
case "$1" in
  show) [ "$3" = ActiveState ] && echo "${FAKE_STATE:-active}" ;;
  is-active)
    shift
    [ "$1" = --quiet ] && shift
    for u in "$@"; do [ -e "$active/$u" ] && exit 0; done
    exit 3 ;;
  enable)
    shift
    for u in "$@"; do
      case $u in *.timer) t=timers.target.wants ;; *) t=default.target.wants ;; esac
      mkdir -p "$FAKE_UNIT_DIR/$t" && ln -sf "$FAKE_UNIT_DIR/$u" "$FAKE_UNIT_DIR/$t/$u"
    done ;;
  disable)
    shift
    now=
    [ "$1" = --now ] && { now=1; shift; }
    for u in "$@"; do
      rm -f "$FAKE_UNIT_DIR"/*.wants/"$u"
      [ -n "$now" ] && rm -f "$active/$u"
    done ;;
  restart)
    shift
    nb=
    [ "$1" = --no-block ] && { nb=1; shift; }
    if [ "$1" = codex-remote-control.service ] && [ -n "${FAKE_FAIL_START:-}" ]; then
      [ -n "$nb" ] && exit 0
      exit 1
    fi
    touch "$active/$1" ;;
esac
exit 0
EOF
cat > "$stubs/codex" <<'EOF'
#!/bin/sh
echo "codex $*" >> "$CALLS"
[ "$*" = "app-server daemon version" ] && exit "${FAKE_VERSION_RC:-0}"
exit 0
EOF
# kill stand-in: a "process" dies by losing its fake /proc directory, unless
# its pid is listed in FAKE_STUBBORN (then only -KILL removes it).
cat > "$stubs/kill" <<'EOF'
#!/bin/sh
sig=$1 pid=$2
echo "kill $sig $pid" >> "$CALLS"
case " ${FAKE_STUBBORN:-} " in
  *" $pid "*) [ "$sig" = -KILL ] && rm -rf "$CRC_PROC/$pid" ;;
  *) rm -rf "$CRC_PROC/$pid" ;;
esac
EOF
chmod +x "$stubs"/*

new_proc() {
  rm -rf "$work/proc" "$FAKE_STATE_DIR" && mkdir -p "$work/proc"
  : > "$calls"
}
# add_proc PID CGROUP-LEAF ARGV...
add_proc() {
  local pid=$1 leaf=$2
  shift 2
  mkdir -p "$work/proc/$pid"
  printf '%s\0' "$@" > "$work/proc/$pid/cmdline"
  printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/%s\n' "$leaf" > "$work/proc/$pid/cgroup"
}
guard() {
  CRC_PROC=$work/proc CRC_SYSTEMCTL=$stubs/systemctl CRC_KILL=$stubs/kill \
    CRC_CODEX=$stubs/codex CRC_SENTINEL=$work/sentinel /bin/sh "$GUARD" "$@"
}
BIN=/home/u/.codex/packages/app-server-daemon/current/bin/codex
DAEMON=("$BIN" app-server --remote-control --listen unix:// --analytics-default-enabled --managed-daemon)
UPDATER=("$BIN" app-server daemon pid-update-loop)
restarted() { grep -qx "systemctl --user restart --no-block $UNIT" "$calls"; }

# --- 1. guard script ---------------------------------------------------------

new_proc
add_proc 101 "$UNIT" "${DAEMON[@]}"
add_proc 102 session-1.scope "${DAEMON[@]}"
add_proc 103 session-1.scope "${UPDATER[@]}"
add_proc 104 session-1.scope codex app-server                    # IDE stdio server
add_proc 105 session-1.scope codex app-server daemon version     # lifecycle command
add_proc 106 session-1.scope /bin/zsh -l
# The patterns inside ONE argument: shells, pkill -f, watch loops.
add_proc 107 session-1.scope pkill -f 'app-server daemon pid-update-loop'
add_proc 108 session-1.scope /bin/zsh -c 'codex app-server --listen unix:// --remote-control'
add_proc 109 session-1.scope watch -n5 'ps aux | grep -c "codex app-server --listen unix:// "'
add_proc 110 session-1.scope /bin/sh -c codex app-server daemon pid-update-loop
guard evict 2>"$work/evict.err"
rc=$?
check "evict exits 0 after clearing outside processes" '[ "$rc" = 0 ]'
check "evict asks Codex to stop its daemon first" 'grep -qx "codex app-server daemon stop" "$calls"'
check "evict terminates the outside daemon and updater" 'grep -qx "kill -TERM 102" "$calls" && grep -qx "kill -TERM 103" "$calls"'
check "evict leaves the daemon inside the unit alone" '! grep -q "kill .* 101$" "$calls" && [ -d "$work/proc/101" ]'
check "evict ignores IDE servers, lifecycle commands and shells" '! grep -qE "kill .* (104|105|106)$" "$calls"'
check "evict ignores processes whose arguments only mention the daemon" '! grep -qE "kill .* (107|108|109|110)$" "$calls"'

new_proc
add_proc 101 "$UNIT" "${DAEMON[@]}"
guard evict 2>/dev/null
check "evict with nothing outside does not call Codex" '! grep -q "^codex" "$calls"'

new_proc
add_proc 102 session-1.scope "${DAEMON[@]}"
FAKE_STUBBORN=102 guard evict 2>"$work/evict.err"
check "evict escalates to KILL for a process that ignores TERM" 'grep -qx "kill -KILL 102" "$calls" && [ ! -d "$work/proc/102" ]'

# watchdog
new_proc
add_proc 101 "$UNIT" "${DAEMON[@]}"
add_proc 107 session-1.scope pkill -f 'app-server daemon pid-update-loop'
add_proc 109 session-1.scope watch -n5 'ps aux | grep -c "codex app-server --listen unix:// "'
guard watch 2>/dev/null
check "watch: healthy daemon inside the unit (and look-alike shells) -> no restart" '! restarted'

new_proc
add_proc 102 session-1.scope "${DAEMON[@]}"
guard watch 2>/dev/null
check "watch: daemon outside the unit -> restart" 'restarted'

new_proc
add_proc 101 "$UNIT" "${DAEMON[@]}"
add_proc 103 session-1.scope "${UPDATER[@]}"
guard watch 2>/dev/null
check "watch: updater outside the unit -> restart" 'restarted'

new_proc
add_proc 101 "$UNIT" "${DAEMON[@]}"
add_proc 107 "$UNIT" "${UPDATER[@]}"
guard watch 2>/dev/null
check "watch: updater inside the unit (auto-update is off) -> restart" 'restarted'

new_proc
guard watch 2>/dev/null
check "watch: no daemon -> restart" 'restarted'

new_proc
add_proc 101 "$UNIT" "${DAEMON[@]}"
FAKE_VERSION_RC=1 guard watch 2>/dev/null
check "watch: daemon not answering -> restart" 'restarted'

new_proc
FAKE_STATE=activating guard watch 2>/dev/null
check "watch: unit still starting -> no restart" '! restarted'

new_proc
add_proc 102 session-1.scope "${DAEMON[@]}"
touch "$work/sentinel"
guard watch 2>/dev/null
check "watch: owner sentinel -> does nothing at all" '[ ! -s "$calls" ]'
rm -f "$work/sentinel"

# stop-updater
new_proc
add_proc 101 "$UNIT" "${DAEMON[@]}"
add_proc 103 session-1.scope "${UPDATER[@]}"
add_proc 107 "$UNIT" "${UPDATER[@]}"
add_proc 108 session-1.scope pkill -f 'app-server daemon pid-update-loop'
guard stop-updater 2>/dev/null
check "stop-updater stops every updater and nothing else" \
  'grep -qx "kill -TERM 103" "$calls" && grep -qx "kill -TERM 107" "$calls" && [ -d "$work/proc/101" ] && [ -d "$work/proc/108" ]'

# run: environment scrubbing
out=$(env GITHUB_TOKEN=x CLAUDE_CODE_MESSAGING_TOKEN=x CLAUDE_CODE_MESSAGING_SOCKET=x HERDR_SOCKET_PATH=x \
  AWS_SECRET_ACCESS_KEY=x my_api_token=x SSH_AUTH_SOCK=x GPG_AGENT_INFO=x KEEP_ME=1 'GLOB*TOKEN=x' \
  /bin/sh "$GUARD" run env)
check "run strips tokens, secrets, Claude/Herdr session and agent sockets" \
  '! printf "%s\n" "$out" | grep -qiE "^(GITHUB_TOKEN|CLAUDE_CODE_|HERDR_|AWS_SECRET|my_api_token|SSH_AUTH_SOCK|GPG_AGENT_INFO|GLOB)"'
check "run keeps ordinary variables and PATH" 'printf "%s\n" "$out" | grep -qx "KEEP_ME=1" && printf "%s\n" "$out" | grep -q "^PATH="'

# wait-dns
CRC_DNS_HOST=localhost CRC_DNS_TIMEOUT=4 /bin/sh "$GUARD" wait-dns 2>/dev/null
check "wait-dns returns 0 once the name resolves" '[ $? = 0 ]'
start=$(date +%s)
CRC_DNS_HOST=does-not-exist.invalid CRC_DNS_TIMEOUT=2 CRC_POLL=1 /bin/sh "$GUARD" wait-dns 2>/dev/null
rc=$?
elapsed=$(($(date +%s) - start))
check "wait-dns gives up after its bound with a non-zero status" '[ "$rc" != 0 ] && [ "$elapsed" -lt 10 ]'

# updater-off
settings=$work/daemon/settings.json
/bin/sh "$GUARD" updater-off --check "$settings"
check "updater-off --check fails while the file is missing" '[ $? != 0 ]'
/bin/sh "$GUARD" updater-off "$settings"
check "updater-off creates the file with the updater disabled" \
  '/usr/bin/python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(d != {\"updater\": {\"autoUpdateEnabled\": False}})" "$settings"'
printf '{"remoteControlEnabled": true, "featureOverrides": {"x": true}, "updater": {"updateIntervalMinutes": 30, "autoUpdateEnabled": true}, "shutdownGraceSeconds": 10}' > "$settings"
/bin/sh "$GUARD" updater-off "$settings"
check "updater-off keeps every other key" \
  '/usr/bin/python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(d != {\"remoteControlEnabled\": True, \"featureOverrides\": {\"x\": True}, \"updater\": {\"updateIntervalMinutes\": 30, \"autoUpdateEnabled\": False}, \"shutdownGraceSeconds\": 10})" "$settings"'
/bin/sh "$GUARD" updater-off --check "$settings"
check "updater-off --check passes afterwards" '[ $? = 0 ]'

# --- 2. recipe ---------------------------------------------------------------

if [ ! -d /run/systemd/system ]; then
  echo "skip: recipe scenarios need a systemd host (the recipe refuses to run without one)"
else
  uid=$(id -u)
  # fresh_home DIR: an empty fixture HOME (its fake bus socket is added by make_bus)
  fresh_home() {
    rm -rf "$1" && mkdir -p "$1" && touch "$1/.fixture-home"
    rm -rf "$FAKE_STATE_DIR"
  }
  make_bus() {
    mkdir -p "$1/run/user/$uid"
    /usr/bin/python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1/run/user/$uid/bus"
    if [ ! -S "$1/run/user/$uid/bus" ]; then
      echo "FATAL: could not create the fake user-bus socket under $1" >&2
      exit 2
    fi
  }
  render() { # render HOME [ENV=VAL...]
    local h=$1
    shift
    : > "$calls"
    env "$@" FAKE_UNIT_DIR="$h/.config/systemd/user" PATH="$stubs:$PATH" \
      ruby "$RENDER" "$RECIPE" "$h" > "$work/render.out" 2> "$work/render.err"
  }
  expect_calls() { diff <(printf '%s\n' "$@") "$calls" > "$work/calls.diff"; }

  # 2a. no user bus
  home=$work/h1
  fresh_home "$home"
  render "$home"
  rc=$?
  units_dir=$home/.config/systemd/user
  check "no user bus: the apply exits 0" '[ "$rc" = 0 ]'
  check "no user bus: a WARN names the missing bus" 'grep -q "WARN: no systemd user bus" "$work/render.err"'
  check "no user bus: no systemctl call" '[ ! -s "$calls" ]'
  check "units and guard are placed" \
    '[ -f "$units_dir/$UNIT" ] && [ -f "$units_dir/codex-remote-control-watch.service" ] && [ -f "$units_dir/$TIMER" ] && [ -x "$home/.local/share/codex-remote-control/guard.sh" ]'
  check "the daemon auto-updater is turned off" \
    '/bin/sh "$GUARD" updater-off --check "$home/.codex/app-server-daemon/settings.json"'

  # 2b. first apply with the bus: one restart, timer first, service non-blocking
  home=$work/h2
  fresh_home "$home"
  make_bus "$home"
  render "$home"
  units_dir=$home/.config/systemd/user
  check "first apply: exactly daemon-reload, enable, restart timer, restart --no-block service" \
    'expect_calls "systemctl --user daemon-reload" "systemctl --user enable $UNIT $TIMER" "systemctl --user restart $TIMER" "systemctl --user restart --no-block $UNIT"'
  check "first apply: the reload ran once" '[ "$(grep -c "reload codex-remote-control units" "$work/render.out")" = 1 ]'

  # 2c. converged
  render "$home"
  check "converged: no systemctl call except the is-active probe" \
    '! grep -vqx "systemctl --user is-active --quiet $TIMER" "$calls"'
  check "converged: no resource runs or changes" '! grep -qE " (ran|changed)" "$work/render.out"'

  # 2d. the guard script changes -> one reload (the daemon picks up the new scrub list)
  echo "# changed" >> "$home/.local/share/codex-remote-control/guard.sh"
  render "$home"
  check "guard change: the service is restarted once" '[ "$(grep -c "restart --no-block $UNIT" "$calls")" = 1 ]'

  # 2e. a failing first start does not fail the apply and leaves the timer running
  home=$work/h3
  fresh_home "$home"
  make_bus "$home"
  render "$home" FAKE_FAIL_START=1
  rc=$?
  check "failing start: the apply still exits 0" '[ "$rc" = 0 ]'
  check "failing start: the watchdog timer was started before the service" \
    '[ -e "$FAKE_STATE_DIR/active/$TIMER" ] && [ "$(grep -n "restart $TIMER" "$calls" | cut -d: -f1)" -lt "$(grep -n "restart --no-block $UNIT" "$calls" | cut -d: -f1)" ]'
  rm -f "$FAKE_STATE_DIR/active/$TIMER"
  render "$home"
  check "timer not running on a later apply: activation runs again" 'grep -qx "systemctl --user restart $TIMER" "$calls"'

  # 2f. sentinel
  home=$work/h2
  units_dir=$home/.config/systemd/user
  touch "$home/.config/codex-remote-control.disabled"
  render "$home"
  check "sentinel: both units are disabled and stopped" 'grep -qx "systemctl --user disable --now $TIMER $UNIT" "$calls"'
  check "sentinel: nothing is enabled or restarted" '! grep -qE "systemctl --user (enable|restart)" "$calls"'
  render "$home"
  check "sentinel, already off: nothing runs" '! grep -qE " (ran|changed)" "$work/render.out" && ! grep -q "disable" "$calls"'

  # Enable symlinks gone (e.g. `disable` without --now) but the unit still active.
  touch "$FAKE_STATE_DIR/active/$UNIT"
  render "$home"
  check "sentinel, unit active but not enabled: it is stopped" 'grep -qx "systemctl --user disable --now $TIMER $UNIT" "$calls"'

  echo "# changed" >> "$units_dir/$UNIT"
  render "$home"
  check "sentinel + changed unit: only daemon-reload" '[ "$(grep -v "is-active" "$calls")" = "systemctl --user daemon-reload" ]'
  check "sentinel + changed unit: WARN names the sentinel" 'grep -q "codex-remote-control.disabled exists" "$work/render.err"'

  rm -f "$home/.config/codex-remote-control.disabled"
  render "$home"
  check "sentinel removed: the next apply enables again" 'grep -q "systemctl --user enable" "$calls"'

  # 2g. root apply (pro-dev's auto-mitamae): everything runs as the workstation user
  home=$work/h4
  fresh_home "$home"
  make_bus "$home"
  render "$home" FIXTURE_UID=0 FIXTURE_ROOT_HOME="$home"
  check "root apply: every resource is owned or run by shin1ohno" \
    '[ -s "$work/render.out" ] && ! grep "^RESOURCE" "$work/render.out" | grep -qv " as shin1ohno$"'
  check "root apply: activation happens" 'grep -q "systemctl --user enable" "$calls"'
  render "$home" FIXTURE_UID=0 FIXTURE_ROOT_HOME=
  check "root apply, user unresolvable: WARN and nothing declared" \
    'grep -q "could not be resolved" "$work/render.out" && ! grep -q "^RESOURCE" "$work/render.out"'

  # 2h. attribute off
  render "$home" FIXTURE_ATTRIBUTE=false
  check "attribute off: the recipe declares nothing" '[ ! -s "$work/render.out" ] && [ ! -s "$calls" ]'
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all checks passed"
