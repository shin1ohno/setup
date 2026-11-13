#!/bin/sh
# Managed by setup (cookbooks/codex-cli/remote_control.rb). Do not edit by hand.
#
# Helper for the codex-remote-control systemd user units. Codex's own daemon
# management (`codex remote-control start`) launches the app-server daemon from
# whatever process calls it and tracks it with pid files; it has no notion of a
# systemd unit. This script keeps that daemon inside the unit:
#
#   wait-dns           wait (bounded) until the remote-control relay resolves
#   evict              stop every daemon / updater process running OUTSIDE the
#                      unit's cgroup, so the next start launches it inside
#   run CMD...         exec CMD with session secrets removed from the environment
#   stop-updater       stop every `app-server daemon pid-update-loop` process
#   watch              timer body: restart the unit when the daemon is missing,
#                      not answering, running outside the unit's cgroup, or
#                      an auto-updater runs at all
#   updater-off FILE   make FILE (the daemon settings.json) carry
#                      "updater": {"autoUpdateEnabled": false}, keeping every
#                      other key; `updater-off --check FILE` only tests it
#
# Every external dependency is an environment knob so the logic can be tested
# against a fake /proc (cookbooks/codex-cli/test/test-remote-control-guard.sh).

set -u

UNIT=${CRC_UNIT:-codex-remote-control.service}
SENTINEL=${CRC_SENTINEL:-$HOME/.config/codex-remote-control.disabled}
PROC=${CRC_PROC:-/proc}
SYSTEMCTL=${CRC_SYSTEMCTL:-systemctl}
KILL=${CRC_KILL:-kill}
CODEX=${CRC_CODEX:-codex}
PYTHON=${CRC_PYTHON:-/usr/bin/python3}
DNS_HOST=${CRC_DNS_HOST:-chatgpt.com}
DNS_TIMEOUT=${CRC_DNS_TIMEOUT:-120}
POLL=${CRC_POLL:-2}
MY_UID=$(id -u)

log() { printf 'codex-remote-control-guard: %s\n' "$*" >&2; }

# True when the process directory $1 belongs to the unit's cgroup. Matches on
# the last path component so it works for cgroup v2 ("0::/…/<unit>") and v1.
in_unit_cgroup() {
  grep -q "/${UNIT}\$" "$1/cgroup" 2>/dev/null
}

# Classify one process from its NUL-separated argv on stdin: print "daemon",
# "updater" or nothing. Fields are compared exactly, never as a substring of
# the joined command line, so a shell, `pkill -f`, `grep` or `watch` whose
# arguments merely mention these words is not a match. The shapes are the ones
# the daemon launcher uses (codex-rs/app-server-daemon/src/backend/pid.rs,
# command_args), with argv[0] the managed `codex` binary:
#   daemon:  codex app-server [--remote-control] --listen unix:// …
#   updater: codex app-server daemon pid-update-loop …
# A stdio `codex app-server` (IDE) or a lifecycle command
# (`codex app-server daemon version|stop`) matches neither.
classify() {
  tr '\000' '\n' | awk '
    NR == 1 { n = split($0, parts, "/"); bin = parts[n] }
    NR == 2 { a1 = $0 }
    NR == 3 { a2 = $0 }
    NR == 4 { a3 = $0 }
    NR > 2 && prev == "--listen" && $0 == "unix://" { listen = 1 }
    { prev = $0 }
    END {
      if (bin != "codex" || a1 != "app-server") exit
      if (a2 == "daemon" && a3 == "pid-update-loop") print "updater"
      else if (listen) print "daemon"
    }'
}

# Print "<kind> <pid> <in|out>" for every Codex daemon or updater process
# owned by this user.
scan() {
  for dir in "$PROC"/[0-9]*; do
    [ -r "$dir/cmdline" ] || continue
    owner=$(stat -c %u "$dir" 2>/dev/null) || continue
    [ "$owner" = "$MY_UID" ] || continue
    kind=$(classify < "$dir/cmdline" 2>/dev/null)
    [ -n "$kind" ] || continue
    if in_unit_cgroup "$dir"; then where=in; else where=out; fi
    printf '%s %s %s\n' "$kind" "${dir##*/}" "$where"
  done
}

# Send TERM to the given pids, wait up to 10 s, then KILL what is left.
terminate() {
  [ $# -gt 0 ] || return 0
  for pid in "$@"; do "$KILL" -TERM "$pid" 2>/dev/null; done
  tries=0
  while [ "$tries" -lt 10 ]; do
    alive=
    for pid in "$@"; do [ -d "$PROC/$pid" ] && alive="$alive $pid"; done
    [ -z "$alive" ] && return 0
    sleep 1
    tries=$((tries + 1))
  done
  for pid in $alive; do
    log "pid $pid ignored TERM; sending KILL"
    "$KILL" -KILL "$pid" 2>/dev/null
  done
  return 0
}

cmd_wait_dns() {
  waited=0
  while [ "$waited" -lt "$DNS_TIMEOUT" ]; do
    getent hosts "$DNS_HOST" >/dev/null 2>&1 && return 0
    sleep "$POLL"
    waited=$((waited + POLL))
  done
  log "$DNS_HOST did not resolve within ${DNS_TIMEOUT}s; starting anyway (the daemon retries on its own)"
  return 1
}

cmd_evict() {
  outside=$(scan | awk '$3 == "out" { print $2 }')
  [ -n "$outside" ] || return 0
  log "stopping Codex daemon processes outside ${UNIT}: $(echo $outside)"
  # Codex's own stop first: it gives running turns the configured grace
  # period. It only knows the pid-file daemon, so whatever survives it (the
  # updater, a stray daemon) is terminated directly.
  timeout 120 "$CODEX" app-server daemon stop >/dev/null 2>&1 ||
    log "codex app-server daemon stop failed; terminating directly"
  # shellcheck disable=SC2046
  terminate $(scan | awk '$3 == "out" { print $2 }')
  left=$(scan | awk '$3 == "out" { print $2 }')
  if [ -n "$left" ]; then
    log "processes still outside ${UNIT}: $(echo $left)"
    return 1
  fi
  return 0
}

cmd_stop_updater() {
  # shellcheck disable=SC2046
  terminate $(scan | awk '$1 == "updater" { print $2 }')
}

# Names never passed to the daemon: the daemon (and every command a phone
# session runs) inherits this environment, and full-access sessions must not
# receive session credentials from whoever started the unit manager.
is_secret_name() {
  upper=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  case "$upper" in
    GITHUB_TOKEN | SSH_AUTH_SOCK | GPG_AGENT_INFO) return 0 ;;
    CLAUDE_CODE_* | HERDR_*) return 0 ;;
    *TOKEN* | *SECRET*) return 0 ;;
  esac
  return 1
}

cmd_run() {
  [ $# -gt 0 ] || { log "run: missing command"; return 2; }
  # One name per line, no globbing, so an odd name is still matched whole.
  set -f
  IFS='
'
  for name in $(awk 'BEGIN { for (k in ENVIRON) print k }'); do
    if is_secret_name "$name"; then
      set -- -u "$name" "$@"
    fi
  done
  exec env "$@"
}

cmd_watch() {
  if [ -e "$SENTINEL" ]; then
    return 0
  fi
  state=$("$SYSTEMCTL" --user show -p ActiveState --value "$UNIT" 2>/dev/null)
  case "$state" in
    activating | deactivating | reloading) return 0 ;;
  esac
  found=$(scan)
  reason=
  if printf '%s\n' "$found" | grep -q ' out$'; then
    reason="a Codex daemon process runs outside ${UNIT}"
  elif printf '%s\n' "$found" | grep -q '^updater '; then
    # The auto-updater is switched off (owner decision); one running anyway
    # was started before that setting and would relaunch the daemon.
    reason="a Codex daemon auto-updater is running"
  elif ! printf '%s\n' "$found" | grep -q '^daemon .* in$'; then
    reason="no Codex daemon runs inside ${UNIT} (state: ${state:-unknown})"
  elif ! timeout 30 "$CODEX" app-server daemon version >/dev/null 2>&1; then
    reason="the Codex daemon does not answer"
  fi
  [ -n "$reason" ] || return 0
  log "$reason; restarting ${UNIT}"
  "$SYSTEMCTL" --user reset-failed "$UNIT" 2>/dev/null
  "$SYSTEMCTL" --user restart --no-block "$UNIT"
}

cmd_updater_off() {
  check=
  if [ "${1:-}" = "--check" ]; then
    check=1
    shift
  fi
  [ $# -eq 1 ] || { log "updater-off: expected one settings path"; return 2; }
  CRC_CHECK=$check "$PYTHON" - "$1" <<'PY'
import json, os, sys, tempfile

path = sys.argv[1]
check = bool(os.environ.get("CRC_CHECK"))
try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
if not isinstance(data, dict):
    sys.exit("settings file is not a JSON object: " + path)
updater = data.get("updater")
if not isinstance(updater, dict):
    updater = {}
if updater.get("autoUpdateEnabled") is False:
    sys.exit(0)
if check:
    sys.exit(1)
updater["autoUpdateEnabled"] = False
data["updater"] = updater
directory = os.path.dirname(path) or "."
os.makedirs(directory, mode=0o700, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".settings.", suffix=".tmp")
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
}

sub=${1:-}
[ $# -gt 0 ] && shift
case "$sub" in
  wait-dns) cmd_wait_dns ;;
  evict) cmd_evict ;;
  run) cmd_run "$@" ;;
  stop-updater) cmd_stop_updater ;;
  watch) cmd_watch ;;
  updater-off) cmd_updater_off "$@" ;;
  *)
    log "usage: $0 wait-dns|evict|run CMD...|stop-updater|watch|updater-off [--check] FILE"
    exit 2
    ;;
esac
