#!/bin/bash
# et-watchdog (linux) — listener self-heal for etserver (issue #567).
#
# systemd supervises et.service process liveness but not whether etserver is
# accepting on port 2022. Mirrors the alive-but-not-listening failure class that
# wedged etserver on mini (2026-06). Driven every ~60s by et-watchdog.timer.
# Restart is LOCAL (`systemctl restart et.service`, same host as etserver) —
# unlike unbound-watchdog which restarts an off-box CT via `pct exec`.
#
# Emits node_exporter textfile metrics so Prometheus/Grafana/Alertmanager SEE
# every outage even after the watchdog auto-heals it — a rising
# et_watchdog_restart_total drives the EternalTerminalFlapping Prometheus alert
# (cookbooks/lxc-monitoring/files/alerts/et-watchdog.yml), surfacing a chronic
# wedge a pure local-recover-and-forget design would hide. (These metrics feed
# Alertmanager, not self-heal GitHub issues — the self-heal observer reads Kibana
# alerts-as-data; the et self-heal-issue path is the Kibana synthetics TCP probe.)
set -uo pipefail

PORT="${ET_PORT:-2022}"
UNIT="${ET_UNIT:-et.service}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
OUT="${TEXTFILE_DIR}/et-watchdog.prom"
STATE_DIR="${STATE_DIR:-/var/lib/et-watchdog}"
STATE="${STATE_DIR}/restart_total"

mkdir -p "${TEXTFILE_DIR}" "${STATE_DIR}"
[[ -f "${STATE}" ]] || echo 0 >"${STATE}"
restart_total=$(cat "${STATE}" 2>/dev/null || echo 0)

probe() {
  # bash /dev/tcp avoids an nc/ncat package dependency on minimal LXC trixie
  # templates. timeout 2 keeps the probe well under the 60s timer interval.
  timeout 2 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/${PORT}" 2>/dev/null
}

up=1
if ! probe; then
  logger -t et-watchdog "etserver port ${PORT} not listening — restarting ${UNIT}"
  systemctl restart "${UNIT}" >/dev/null 2>&1
  restart_total=$((restart_total + 1))
  echo "${restart_total}" >"${STATE}"
  sleep 3
  if probe; then
    logger -t et-watchdog "${UNIT} restarted; port ${PORT} listening again"
  else
    up=0
    logger -t et-watchdog "${UNIT} restart did NOT restore port ${PORT}"
  fi
fi

now=$(date +%s)
tmp=$(mktemp "${OUT}.XXXXXX")
trap 'rm -f "${tmp}"' EXIT
{
  echo "# HELP et_watchdog_up etserver TCP port accepting connections (1) or not (0)"
  echo "# TYPE et_watchdog_up gauge"
  echo "et_watchdog_up{port=\"${PORT}\"} ${up}"
  echo "# HELP et_watchdog_restart_total Cumulative et restarts triggered by the watchdog"
  echo "# TYPE et_watchdog_restart_total counter"
  echo "et_watchdog_restart_total{port=\"${PORT}\"} ${restart_total}"
  echo "# HELP et_watchdog_last_check_timestamp_seconds Unix time of the last watchdog probe"
  echo "# TYPE et_watchdog_last_check_timestamp_seconds gauge"
  echo "et_watchdog_last_check_timestamp_seconds ${now}"
} >"${tmp}"
mv "${tmp}" "${OUT}"
trap - EXIT
chmod 0644 "${OUT}"
