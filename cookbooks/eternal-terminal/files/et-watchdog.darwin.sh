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
#
# SCOPE — what this probe does and does NOT cover (setup #567 vs #603):
#   - COVERS #567 (real wedge): etserver holds zero sockets, so a loopback
#     connect() is REFUSED. Detectable here → kickstart restores the listener.
#   - DOES NOT COVER #603 (sleep): when the Mac idle-sleeps the whole net stack
#     is down, external probes SYN-drop (timeout), and a StartInterval timer does
#     not even fire during sleep — nothing to kickstart, and kickstarting would
#     not help. That class is fixed by keeping the host awake (mac-settings
#     `pmset -c sleep 0`) and observed centrally by the CT111 Kibana synthetics
#     TCP probe — NOT by this watchdog. Do not widen this probe to chase it.
set -uo pipefail

PORT="${ET_PORT:-2022}"
LABEL="${ET_LABEL:-system/homebrew.mxcl.et}"

# BSD nc ships on macOS. -z = scan (no I/O). NOTE: on macOS nc, -w is the IDLE
# timeout, NOT the connect() timeout — it does not bound a hung SYN. That is
# fine here because the target is loopback: 127.0.0.1 connect() resolves
# instantly (accept or RST, no SYN retransmit), so the probe stays well under
# the 60s StartInterval.
probe() { /usr/bin/nc -z -w 2 127.0.0.1 "${PORT}" 2>/dev/null; }

# Two-strike debounce before the disruptive kickstart. `kickstart -k` KILLS
# etserver and drops every live `et` session, so a single false-negative probe
# (a momentary loopback hiccup) must not trigger a restart. A genuine listener
# wedge stays down across both probes; a transient clears on the second.
if ! probe; then
  sleep 3
  if ! probe; then
    logger -t et-watchdog "etserver port ${PORT} not listening (2 probes) — launchctl kickstart -k ${LABEL}"
    launchctl kickstart -k "${LABEL}"
    sleep 3
    if probe; then
      logger -t et-watchdog "etserver kickstarted; port ${PORT} listening again"
    else
      logger -t et-watchdog "etserver kickstart did NOT restore port ${PORT}"
    fi
  fi
fi
