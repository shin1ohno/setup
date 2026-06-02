#!/bin/bash
# unbound-watchdog.sh — off-box self-heal for the LAN DNS resolver (CT 118 / .61).
#
# Runs on the PVE host via unbound-watchdog.timer (~60s). Two independent probes:
#
#   1. LOCAL canary (unbound-watchdog.health, local-data) over the LAN (NOT
#      loopback) — detects the "active + bound but zero replies on eth0" wedge
#      and stale-config (deployed-but-not-reloaded). Recovery: restart unbound.
#
#   2. FORWARD canary (a public name via the `.` DoT forwarders) — detects a
#      forwarder wedge that the local-data canary CANNOT see: unbound stays up
#      and answers local-data while a forwarder's infra-cache RTO is maxed at
#      120000ms (after a transient VPC/DoT blip) and every forwarded query
#      SERVFAILs. This is the 2026-06-02 home.local-forward-wedge failure class.
#      Recovery: `unbound-control flush_infra all` (clears the stuck backoff for
#      ALL forwarders), and only a full restart if that does not recover it.
#
# On failure it acts inside the CT and records node_exporter textfile metrics
# (the PVE host's node-exporter is already scraped by Prometheus on monitoring).
set -uo pipefail

CT_ID="${CT_ID:-118}"
RESOLVER_IP="${RESOLVER_IP:-192.168.1.61}"
CANARY="${CANARY:-unbound-watchdog.health}"
EXPECT="${EXPECT:-192.0.2.1}"
# Forward-path canary: a public name that REQUIRES the `.` DoT forwarders (it is
# NOT local-data). Any A answer means the forward path is healthy.
FWD_CANARY="${FWD_CANARY:-one.one.one.one}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
OUT="${TEXTFILE_DIR}/unbound-watchdog.prom"
STATE_DIR="${STATE_DIR:-/var/lib/unbound-watchdog}"
STATE="${STATE_DIR}/restart_total"

mkdir -p "${TEXTFILE_DIR}" "${STATE_DIR}"
[[ -f "${STATE}" ]] || echo 0 >"${STATE}"
restart_total=$(cat "${STATE}" 2>/dev/null || echo 0)

probe() {
  # +tries=2 absorbs a single dropped UDP packet; +time=2 keeps the whole probe
  # well under the 60s timer interval. Match the expected sentinel so a stale
  # config (different/empty answer) also counts as failure, not just a timeout.
  local ans
  ans=$(dig +short +time=2 +tries=2 @"${RESOLVER_IP}" "${CANARY}" A 2>/dev/null)
  [[ "${ans}" == "${EXPECT}" ]]
}

forward_probe() {
  # Resolve a public name through the resolver's forward path. Any A answer = the
  # forwarders are responding. +time=3 tolerates the DoT handshake latency.
  local ans
  ans=$(dig +short +time=3 +tries=2 @"${RESOLVER_IP}" "${FWD_CANARY}" A 2>/dev/null)
  [[ -n "${ans}" ]]
}

up=1
fwd_up=1

if ! probe; then
  # Local canary failed: unbound down / wedged / stale config. Restart.
  logger -t unbound-watchdog \
    "resolver ${RESOLVER_IP} canary '${CANARY}' failed — restarting unbound in CT ${CT_ID}"
  pct exec "${CT_ID}" -- systemctl restart unbound >/dev/null 2>&1
  restart_total=$((restart_total + 1))
  echo "${restart_total}" >"${STATE}"
  sleep 3
  if probe; then
    logger -t unbound-watchdog "unbound restarted; resolver ${RESOLVER_IP} healthy again"
  else
    up=0
    logger -t unbound-watchdog "unbound restart did NOT restore resolver ${RESOLVER_IP}"
  fi
else
  # Local canary OK. Check the forward path — a forwarder infra-cache wedge does
  # not affect local-data answers, so this is the only probe that catches it.
  if ! forward_probe; then
    logger -t unbound-watchdog \
      "resolver ${RESOLVER_IP} forward canary '${FWD_CANARY}' failed — flush_infra in CT ${CT_ID}"
    pct exec "${CT_ID}" -- unbound-control flush_infra all >/dev/null 2>&1
    sleep 2
    if forward_probe; then
      logger -t unbound-watchdog "forward path recovered after flush_infra (no restart needed)"
    else
      logger -t unbound-watchdog \
        "forward path still failing after flush_infra — restarting unbound in CT ${CT_ID}"
      pct exec "${CT_ID}" -- systemctl restart unbound >/dev/null 2>&1
      restart_total=$((restart_total + 1))
      echo "${restart_total}" >"${STATE}"
      sleep 3
      if forward_probe; then
        logger -t unbound-watchdog "unbound restarted; forward path healthy again"
      else
        fwd_up=0
        logger -t unbound-watchdog "unbound restart did NOT restore the forward path"
      fi
    fi
  fi
fi

now=$(date +%s)
tmp=$(mktemp "${OUT}.XXXXXX")
trap 'rm -f "${tmp}"' EXIT
{
  echo "# HELP unbound_watchdog_up Resolver answered the local canary over the LAN (1) or not (0)"
  echo "# TYPE unbound_watchdog_up gauge"
  echo "unbound_watchdog_up{target=\"${RESOLVER_IP}\"} ${up}"
  echo "# HELP unbound_watchdog_forward_path_up Resolver answered a forwarded (public) query (1) or not (0)"
  echo "# TYPE unbound_watchdog_forward_path_up gauge"
  echo "unbound_watchdog_forward_path_up{target=\"${RESOLVER_IP}\"} ${fwd_up}"
  echo "# HELP unbound_watchdog_restart_total Cumulative unbound restarts triggered by the watchdog"
  echo "# TYPE unbound_watchdog_restart_total counter"
  echo "unbound_watchdog_restart_total{target=\"${RESOLVER_IP}\"} ${restart_total}"
  echo "# HELP unbound_watchdog_last_check_timestamp_seconds Unix time of the last watchdog probe"
  echo "# TYPE unbound_watchdog_last_check_timestamp_seconds gauge"
  echo "unbound_watchdog_last_check_timestamp_seconds ${now}"
} >"${tmp}"
mv "${tmp}" "${OUT}"
trap - EXIT
chmod 0644 "${OUT}"
