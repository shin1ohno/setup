#!/bin/bash
# unbound-watchdog.sh — off-box self-heal for the LAN DNS resolver (CT 118 / .61).
#
# Runs on the PVE host via unbound-watchdog.timer (~60s). Probes the resolver
# over the LAN (NOT loopback) so it detects the "active + bound but zero replies
# on eth0" wedge that a CT-local probe cannot see: in the 2026-05-31 incident the
# CT answered 127.0.0.1 fine while every off-box query timed out for hours. On
# failure it restarts unbound inside the CT and records the event as a
# node_exporter textfile metric (the PVE host's node-exporter is already scraped
# by Prometheus on the monitoring LXC).
#
# The canary name (unbound-watchdog.health) is defined as local-data in
# cookbooks/unbound/files/home-monitor.conf. A timeout => wedged/down; an
# empty/wrong answer => unbound is running a STALE config that predates the
# canary (deployed-but-not-reloaded, the actual 2026-05-31 root cause). Both
# warrant a restart, so one probe covers both failure modes.
set -uo pipefail

CT_ID="${CT_ID:-118}"
RESOLVER_IP="${RESOLVER_IP:-192.168.1.61}"
CANARY="${CANARY:-unbound-watchdog.health}"
EXPECT="${EXPECT:-192.0.2.1}"
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

up=1
if ! probe; then
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
fi

now=$(date +%s)
tmp=$(mktemp "${OUT}.XXXXXX")
trap 'rm -f "${tmp}"' EXIT
{
  echo "# HELP unbound_watchdog_up Resolver answered the canary over the LAN (1) or not (0)"
  echo "# TYPE unbound_watchdog_up gauge"
  echo "unbound_watchdog_up{target=\"${RESOLVER_IP}\"} ${up}"
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
