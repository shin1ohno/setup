#!/usr/bin/env bash
#
# self-heal-probe.sh — observation helpers for self-heal-resolve. Managed by
# cookbooks/self-heal-loops. Do not edit by hand. Run as a CLI
# (classify_port / diagnose_port_down / check_sleep / --self-test).
#
# WHY THIS EXISTS (setup #603): the resolve loop runs under a sandboxed Bash
# where a LOCAL `netstat` / `lsof` / `launchctl list` can return EMPTY for a
# listener that is actually present. An empty result is NOT evidence of "no
# listener". #603 mis-diagnosed a mini auto-sleep as an etserver wedge because
# an empty netstat was read as proof of a dead listener. These helpers replace
# absence-of-evidence with a REAL TCP connect classification (refused vs
# timeout vs open) plus a darwin sleep correlation, and encode the
# sleep-vs-wedge decision table so the loop cannot skip it in prose.
#
# Connect classification (the key distinction #603 needed):
#   open     = TCP handshake completed                      -> service is up
#   refused  = RST / fast non-zero (host up, no listener)   -> wedge candidate (#567)
#   timeout  = SYN dropped, timeout(1) killed the connect   -> sleep / firewall / route
#
# All connects use timeout(1) + bash /dev/tcp (this helper runs on pro-dev,
# Linux — timeout and /dev/tcp are present). Inputs are validated to keep the
# /dev/tcp path injection-safe.

# --- pure: map a connect exit code to a classification -----------------------
classify_rc() {
  case "${1:-}" in
    0)   echo open ;;
    124) echo timeout ;;   # timeout(1) killed it -> SYN drop / filtered / asleep
    *)   echo refused ;;   # fast non-zero -> RST (host up, nothing listening)
  esac
}

# --- real TCP connect classification -----------------------------------------
# classify_port <host> <port> [timeout_secs]
classify_port() {
  local host="${1:-}" port="${2:-}" t="${3:-5}"
  case "${port}" in ''|*[!0-9]*) echo invalid; return 2 ;; esac
  case "${host}" in ''|*[!a-zA-Z0-9.:_-]*) echo invalid; return 2 ;; esac
  timeout "${t}" bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1
  classify_rc "$?"
}

# --- darwin sleep correlation ------------------------------------------------
# check_sleep <host>  -> sleep-present | no-sleep | unknown
# A macOS host that auto-sleeps drops SYNs to unregistered ports (etserver:2022)
# while Bonjour/Wake-on-Demand still wakes registered services (ssh:22). Recent
# Sleep/DarkWake transitions in `pmset -g log` explain a target-port timeout.
check_sleep() {
  local host="${1:-}" out
  case "${host}" in ''|*[!a-zA-Z0-9.:_-]*) echo unknown; return 2 ;; esac
  out=$(ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
          "${host}" "pmset -g log 2>/dev/null | grep -cE '(\bSleep\b|DarkWake|Maintenance Sleep)'" 2>/dev/null)
  case "${out}" in
    ''|*[!0-9]*) echo unknown ;;
    0)           echo no-sleep ;;
    *)           echo sleep-present ;;
  esac
}

# --- decision table ----------------------------------------------------------
# diagnose_verdict <target_class> <ssh_class> <is_darwin:0|1> <sleep_present:0|1>
#   host-unreachable        : ssh:22 itself not open -> the HOST is down/unreachable,
#                             not a single-service wedge (do not "restart the service")
#   service-up              : the target port is open -> the alert may be stale
#   wedge-suspect           : host up (ssh open), target refused -> listener gone (#567);
#                             a launchctl/systemctl kick is the candidate remediation
#   sleep-suspect           : darwin + target timeout + sleep transitions present (#603);
#                             remediation is power management (class D), NOT a restart
#   sleep-or-filter-suspect : darwin + target timeout, sleep not confirmed
#   filter-or-route-suspect : non-darwin + target timeout -> firewall/route, NOT a wedge
#   inconclusive            : anything else
diagnose_verdict() {
  local tgt="${1:-}" ssh="${2:-}" darwin="${3:-0}" sleep="${4:-0}"
  if [ "${ssh}" != open ]; then echo host-unreachable; return; fi
  case "${tgt}" in
    open)    echo service-up ;;
    refused) echo wedge-suspect ;;
    timeout)
      if   [ "${darwin}" = 1 ] && [ "${sleep}" = 1 ]; then echo sleep-suspect
      elif [ "${darwin}" = 1 ];                        then echo sleep-or-filter-suspect
      else                                                  echo filter-or-route-suspect
      fi ;;
    *)       echo inconclusive ;;
  esac
}

# --- CLI convenience: full port-down diagnosis -------------------------------
# diagnose_port_down <host> <port> [is_darwin:0|1]
diagnose_port_down() {
  local host="${1:-}" port="${2:-}" darwin="${3:-0}" tgt ssh sleep=0 verdict
  tgt=$(classify_port "${host}" "${port}")
  ssh=$(classify_port "${host}" 22)
  if [ "${darwin}" = 1 ] && [ "$(check_sleep "${host}")" = sleep-present ]; then sleep=1; fi
  verdict=$(diagnose_verdict "${tgt}" "${ssh}" "${darwin}" "${sleep}")
  echo "target ${host}:${port}=${tgt}  ssh:22=${ssh}  darwin=${darwin}  sleep_present=${sleep}  => VERDICT: ${verdict}"
  # A non-refused verdict means "do NOT blindly restart" — see the table above.
}

# --- self-test (hermetic logic + live loopback sanity) -----------------------
self_test() {
  local fail=0
  _a() { [ "$1" = "$2" ] || { echo "FAIL: $3 (got '$1' want '$2')"; fail=1; }; }

  # pure rc mapping
  _a "$(classify_rc 0)"   open    "classify_rc 0"
  _a "$(classify_rc 124)" timeout "classify_rc 124"
  _a "$(classify_rc 1)"   refused "classify_rc 1"
  _a "$(classify_rc 7)"   refused "classify_rc 7"

  # decision table
  _a "$(diagnose_verdict timeout open 1 1)" sleep-suspect           "#603 darwin timeout+sleep"
  _a "$(diagnose_verdict refused open 0 0)" wedge-suspect           "#567 refused"
  _a "$(diagnose_verdict refused timeout 0 0)" host-unreachable     "ssh down => host-unreachable"
  _a "$(diagnose_verdict open open 0 0)"    service-up              "target open => service-up"
  _a "$(diagnose_verdict timeout open 0 0)" filter-or-route-suspect "linux timeout => not-wedge"
  _a "$(diagnose_verdict timeout open 1 0)" sleep-or-filter-suspect "darwin timeout, sleep unconfirmed"

  # live loopback sanity: the real connect path must classify a known-open and a
  # known-closed loopback port (loopback RSTs closed ports, so refused is reliable).
  _a "$(classify_port 127.0.0.1 22)" open    "live classify_port 127.0.0.1:22 (open)"
  _a "$(classify_port 127.0.0.1 9 2)" refused "live classify_port 127.0.0.1:9 (closed)"

  if [ "${fail}" = 0 ]; then echo "self-test: PASS"; return 0; fi
  echo "self-test: FAIL"; return 1
}

# --- CLI dispatch (only when executed, not sourced) --------------------------
if [ "${BASH_SOURCE[0]:-$0}" = "${0}" ]; then
  cmd="${1:-}"
  case "${cmd}" in
    --self-test)        self_test ;;
    classify_port)      shift; classify_port "$@" ;;
    diagnose_port_down) shift; diagnose_port_down "$@" ;;
    check_sleep)        shift; check_sleep "$@" ;;
    *) echo "usage: self-heal-probe.sh {--self-test | classify_port <host> <port> [t] | diagnose_port_down <host> <port> [darwin0|1] | check_sleep <host>}" >&2; exit 2 ;;
  esac
fi
