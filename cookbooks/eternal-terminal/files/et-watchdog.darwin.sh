#!/bin/bash
# et-watchdog (darwin) — listener self-heal for etserver (issue #567).
#
# launchd KeepAlive(NetworkState) on homebrew.mxcl.et only restarts etserver on
# network-up transitions and process exit — it CANNOT detect an alive-but-not-
# listening etserver. The 2026-06 mini incident was exactly that: PID alive ~4
# days, zero listening sockets, port 2022 refused, `et` login down. This probe
# (driven every 60s by com.shin1ohno.et-watchdog via StartInterval) closes that
# gap. It is the ONLY recovery path that reaches darwin hosts — the central
# self-heal-resolve loop restarts services via `pct exec` (LXC-only) and has no
# launchctl path to Macs.
set -uo pipefail

PORT="${ET_PORT:-2022}"
LABEL="${ET_LABEL:-system/homebrew.mxcl.et}"

# BSD nc ships on macOS. -z = scan (no I/O). NOTE: on macOS nc, -w is the IDLE
# timeout, NOT the connect() timeout — it does not bound a hung SYN. That is
# fine here because the target is loopback: 127.0.0.1 connect() resolves
# instantly (accept or RST, no SYN retransmit), so the probe stays well under
# the 60s StartInterval. This loopback probe confirms the listener-wedge class
# (the observed mini failure); LAN-interface reachability is covered separately
# by the central Kibana synthetics TCP probe from CT 111.
if ! /usr/bin/nc -z -w 2 127.0.0.1 "${PORT}" 2>/dev/null; then
  logger -t et-watchdog "etserver port ${PORT} not listening — launchctl kickstart -k ${LABEL}"
  launchctl kickstart -k "${LABEL}"
  sleep 3
  if /usr/bin/nc -z -w 2 127.0.0.1 "${PORT}" 2>/dev/null; then
    logger -t et-watchdog "etserver kickstarted; port ${PORT} listening again"
  else
    logger -t et-watchdog "etserver kickstart did NOT restore port ${PORT}"
  fi
fi
