#!/bin/bash
# orchestrator-watchdog.sh — sister cron killing long-running orchestrator
# (and drift-checker) processes that escaped the outer `timeout` wrapper.
#
# Outer cron wraps each job in `timeout 600` (orchestrator) and `timeout 90`
# (drift-checker). Both deliver SIGTERM then SIGKILL on expiry. This script
# is the last-resort backstop for the (rare) cases where the wrapped child
# ignores SIGTERM (sub-shells holding open sockets, network I/O in
# uninterruptible state, signal handlers misbehaving in mitamae mruby fork).
#
# Threshold (12 min) is intentionally longer than the orchestrator timeout
# (10 min) — if everything is working the watchdog never fires, so a
# nonzero kill count is itself a signal that the `timeout` wrapper failed.
# Watchdog emits a Prometheus textfile metric to surface kill events.
#
# Runs every 3 min via cron alongside drift-checker (2 min) and
# orchestrator (5 min).

set -uo pipefail

KILL_THRESHOLD_SEC=720
TEXTFILE=/var/lib/node_exporter/textfile/orchestrator-watchdog.prom

# Walk both binaries — orchestrator hangs were the trigger, but drift-checker
# can hang too (GitHub API stall before the `timeout 90` wrapper landed).
for binary in /usr/local/bin/orchestrator.sh /usr/local/bin/drift-checker.sh; do
  for pid in $(pgrep -f "${binary}" 2>/dev/null || true); do
    etime=$(ps -o etimes= -p "${pid}" 2>/dev/null | tr -d ' ')
    etime=${etime:-0}
    if [[ "${etime}" -gt "${KILL_THRESHOLD_SEC}" ]]; then
      logger -t orchestrator-watchdog \
        "killing ${binary} PID=${pid} (etime=${etime}s > ${KILL_THRESHOLD_SEC}s)"
      kill -TERM "${pid}" 2>/dev/null || true
      # Grace period for clean shutdown before SIGKILL.
      sleep 5
      if kill -0 "${pid}" 2>/dev/null; then
        logger -t orchestrator-watchdog "SIGKILL ${binary} PID=${pid} (SIGTERM ignored)"
        kill -KILL "${pid}" 2>/dev/null || true
      fi
    fi
  done
done

# Emit textfile metric: kill count over the last 5 minutes. node_exporter's
# textfile collector reads this on its own scrape interval. We count from
# journalctl rather than tracking state on disk because journalctl is
# atomic and survives across cycles.
tmp=$(mktemp "${TEXTFILE}.tmp.XXXXXX")
trap 'rm -f "${tmp}"' EXIT

killed_5m=$(journalctl -t orchestrator-watchdog --since "5 min ago" --no-pager 2>/dev/null \
  | grep -c "^.*killing " 2>/dev/null || echo 0)

{
  echo "# HELP orchestrator_watchdog_kills_5m Number of orchestrator/drift-checker SIGTERM events in the last 5 min"
  echo "# TYPE orchestrator_watchdog_kills_5m gauge"
  echo "orchestrator_watchdog_kills_5m ${killed_5m}"
  echo "# HELP orchestrator_watchdog_last_run_timestamp_seconds Unix time of last watchdog cron fire"
  echo "# TYPE orchestrator_watchdog_last_run_timestamp_seconds gauge"
  echo "orchestrator_watchdog_last_run_timestamp_seconds $(date +%s)"
} > "${tmp}"

mv "${tmp}" "${TEXTFILE}"
chmod 0644 "${TEXTFILE}"
