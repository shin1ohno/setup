#!/bin/bash
# unbound-watchdog.sh — off-box self-heal for the LAN DNS resolver (CT 118 / .61).
#
# Runs on the PVE host via unbound-watchdog.timer (~60s). Three independent
# probes; the first two self-heal, the third only reports:
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
#      The canary answer is FLUSHED from unbound's cache before each probe —
#      see forward_probe() for why a cached canary is blind to the wedge.
#
#   3. IPv6 canary (the same local-data name, forced over IPv6 transport to the
#      resolver's ULA) — detects a v6-listener regression that probe 1 cannot
#      see, because unbound binds v4 and v6 as separate sockets. NO recovery
#      action: the causes a restart could fix are already covered by probe 1,
#      and restarting a healthy resolver on a v6-only fault would wipe the LAN
#      cache repeatedly. See the v6_up block below for the full reasoning.
#
# On failure it acts inside the CT and records node_exporter textfile metrics
# (the PVE host's node-exporter is already scraped by Prometheus on monitoring).
set -uo pipefail

CT_ID="${CT_ID:-118}"
RESOLVER_IP="${RESOLVER_IP:-192.168.1.61}"
# IPv6 transport probe target. This is the resolver's ULA, NOT its GUA: the GUA
# is built from the DHCPv6-PD delegated prefix, which has already rotated twice,
# so a GUA literal here would go stale and then report a healthy resolver as
# down on every cycle. The ULA prefix is ours (RFC 4193, fixed in home-monitor
# devices.tf) and the host part is EUI-64 from CT 118's pinned MAC, so it only
# changes if that MAC changes. Set RESOLVER_V6="" to disable the probe.
RESOLVER_V6="${RESOLVER_V6-fd97:b085:767d:0:be24:11ff:fe00:76}"
CANARY="${CANARY:-unbound-watchdog.health}"
EXPECT="${EXPECT:-192.0.2.1}"
# Forward-path canary: a public name that REQUIRES the `.` DoT forwarders (it is
# NOT local-data). Any A answer means the forward path is healthy.
FWD_CANARY="${FWD_CANARY:-one.one.one.one}"
# Flush the forward canary from unbound's cache before probing it (see
# forward_probe). Set to 0 only to fall back to the old cache-served probe.
FWD_FLUSH="${FWD_FLUSH:-1}"
# Minimum seconds between two unbound restarts. flush_infra still runs on every
# failing cycle; only the heavier restart is rate-limited. Without this, a real
# upstream outage (ISP/DoT unreachable for an hour) would restart unbound every
# 60s and drop the whole LAN cache each time — making DNS worse, not better.
RESTART_MIN_INTERVAL="${RESTART_MIN_INTERVAL:-900}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
OUT="${TEXTFILE_DIR}/unbound-watchdog.prom"
STATE_DIR="${STATE_DIR:-/var/lib/unbound-watchdog}"
STATE="${STATE_DIR}/restart_total"
LAST_RESTART="${STATE_DIR}/last_restart"
FWD_WEDGE_STATE="${STATE_DIR}/forward_wedge_total"

mkdir -p "${TEXTFILE_DIR}" "${STATE_DIR}"
[[ -f "${STATE}" ]] || echo 0 >"${STATE}"
[[ -f "${FWD_WEDGE_STATE}" ]] || echo 0 >"${FWD_WEDGE_STATE}"

# read_counter <file> -> integer (0 when the file is missing/garbage)
read_counter() {
  local v
  v=$(cat "${1}" 2>/dev/null || echo 0)
  case "${v}" in ''|*[!0-9]*) echo 0 ;; *) echo "${v}" ;; esac
}

restart_total=$(read_counter "${STATE}")
forward_wedge_total=$(read_counter "${FWD_WEDGE_STATE}")

probe() {
  # +tries=2 absorbs a single dropped UDP packet; +time=2 keeps the whole probe
  # well under the 60s timer interval. Match the expected sentinel so a stale
  # config (different/empty answer) also counts as failure, not just a timeout.
  local ans
  ans=$(dig +short +time=2 +tries=2 @"${RESOLVER_IP}" "${CANARY}" A 2>/dev/null)
  [[ "${ans}" == "${EXPECT}" ]]
}

v6_probe() {
  # Same canary as probe(), but forced over IPv6 transport to the resolver's ULA.
  # This is the ONLY probe that sees an IPv6-listener regression: unbound binds
  # v4 and v6 as separate sockets (verified on CT 118 — `0.0.0.0:53` and
  # `[::]:53` appear as distinct rows, V6ONLY is set even with
  # net.ipv6.bindv6only=0), so the v4 canary stays green while the v6 socket is
  # missing, refused by access-control, or unreachable.
  #
  # -6 is explicit rather than inferred from the address so a mistyped literal
  # fails as "no v6 answer" instead of silently falling back to v4.
  local ans
  ans=$(dig -6 +short +time=2 +tries=2 @"${RESOLVER_V6}" "${CANARY}" A 2>/dev/null)
  [[ "${ans}" == "${EXPECT}" ]]
}

forward_probe() {
  # Resolve a public name through the resolver's forward path. Any A answer = the
  # forwarders are responding. +time=3 tolerates the DoT handshake latency.
  #
  # The cache flush is load-bearing, not hygiene: unbound.conf sets
  # `prefetch: yes`, so a popular cached answer is refreshed in the background
  # and KEEPS BEING SERVED even while every *new* forwarded lookup SERVFAILs.
  # A cache-served canary therefore stays green straight through a forward
  # wedge — observed 2026-07-25 (setup#748/#749/#750/#752): LAN clients got
  # SERVFAIL on every public name for ~35 min in flapping multi-minute windows,
  # while this watchdog logged nothing, unbound_watchdog_forward_path_up stayed
  # 1 and restart_total never moved. Flushing the canary first forces a real
  # forwarded resolution on every cycle, which is what LAN clients actually do.
  if [[ "${FWD_FLUSH}" == "1" ]]; then
    pct exec "${CT_ID}" -- unbound-control flush "${FWD_CANARY}" >/dev/null 2>&1
  fi
  local ans
  ans=$(dig +short +time=3 +tries=2 @"${RESOLVER_IP}" "${FWD_CANARY}" A 2>/dev/null)
  [[ -n "${ans}" ]]
}

# restart_unbound <reason> -> 0 when the restart ran, 1 when suppressed by the
# backoff. Rate-limited so a sustained upstream outage cannot turn a per-minute
# timer into a per-minute cache-wipe.
restart_unbound() {
  local reason="${1}" now last
  now=$(date +%s)
  last=$(read_counter "${LAST_RESTART}")
  if (( now - last < RESTART_MIN_INTERVAL )); then
    logger -t unbound-watchdog \
      "restart SUPPRESSED (${reason}): last restart $((now - last))s ago < ${RESTART_MIN_INTERVAL}s backoff"
    return 1
  fi
  pct exec "${CT_ID}" -- systemctl restart unbound >/dev/null 2>&1
  echo "${now}" >"${LAST_RESTART}"
  restart_total=$((restart_total + 1))
  echo "${restart_total}" >"${STATE}"
  sleep 3
  return 0
}

up=1
fwd_up=1

if ! probe; then
  # Local canary failed: unbound down / wedged / stale config. Restart.
  logger -t unbound-watchdog \
    "resolver ${RESOLVER_IP} canary '${CANARY}' failed — restarting unbound in CT ${CT_ID}"
  restart_unbound "local canary"
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
    forward_wedge_total=$((forward_wedge_total + 1))
    echo "${forward_wedge_total}" >"${FWD_WEDGE_STATE}"
    logger -t unbound-watchdog \
      "resolver ${RESOLVER_IP} forward canary '${FWD_CANARY}' failed — flush_infra in CT ${CT_ID}"
    pct exec "${CT_ID}" -- unbound-control flush_infra all >/dev/null 2>&1
    sleep 2
    if forward_probe; then
      logger -t unbound-watchdog "forward path recovered after flush_infra (no restart needed)"
    else
      logger -t unbound-watchdog \
        "forward path still failing after flush_infra — restarting unbound in CT ${CT_ID}"
      if restart_unbound "forward canary"; then
        if forward_probe; then
          logger -t unbound-watchdog "unbound restarted; forward path healthy again"
        else
          fwd_up=0
          logger -t unbound-watchdog "unbound restart did NOT restore the forward path"
        fi
      else
        # Backoff suppressed the restart; the forward path is still down. Report
        # it so the alert fires instead of silently looking recovered.
        fwd_up=0
      fi
    fi
  fi
fi

# IPv6 transport check — OBSERVE ONLY, deliberately no recovery action.
#
# Everything above can be fixed by acting on unbound (restart / flush_infra),
# which is why those probes trigger. A v6-only failure usually cannot: the
# common causes are the resolver losing its ULA (RA stopped, addr_gen_mode
# changed), a route disappearing on this host, or the `fd97:b085:767d::/64`
# access-control line being dropped from unbound.conf. Restarting unbound fixes
# none of those, and doing it anyway would mean restarting a HEALTHY resolver
# every RESTART_MIN_INTERVAL for as long as the condition lasts, dropping the
# whole LAN cache each time -- v4 clients would be harmed by a v6 fault. So this
# reports and lets UnboundResolverIPv6Down page a human instead.
v6_up=1
if [[ -n "${RESOLVER_V6}" ]]; then
  if ! v6_probe; then
    v6_up=0
    logger -t unbound-watchdog \
      "resolver ${RESOLVER_V6} (IPv6) canary '${CANARY}' failed — reporting only, no restart (see UnboundResolverIPv6Down)"
  fi
fi

now=$(date +%s)
tmp=$(mktemp "${OUT}.XXXXXX")
trap 'rm -f "${tmp}"' EXIT
{
  echo "# HELP unbound_watchdog_up Resolver answered the local canary over the LAN (1) or not (0)"
  echo "# TYPE unbound_watchdog_up gauge"
  echo "unbound_watchdog_up{target=\"${RESOLVER_IP}\"} ${up}"
  # Deliberately a SEPARATE metric name rather than another target= label on
  # unbound_watchdog_up: that metric drives UnboundResolverDown at severity
  # critical ("the whole LAN lost name resolution"), which is true for the v4
  # path every client uses and false for a v6-only fault. Re-keying the existing
  # series with an extra label would also break its history mid-flight.
  if [[ -n "${RESOLVER_V6}" ]]; then
    echo "# HELP unbound_watchdog_v6_up Resolver answered the local canary over IPv6 transport (1) or not (0)"
    echo "# TYPE unbound_watchdog_v6_up gauge"
    echo "unbound_watchdog_v6_up{target=\"${RESOLVER_V6}\"} ${v6_up}"
  fi
  echo "# HELP unbound_watchdog_forward_path_up Resolver answered a forwarded (public) query (1) or not (0)"
  echo "# TYPE unbound_watchdog_forward_path_up gauge"
  echo "unbound_watchdog_forward_path_up{target=\"${RESOLVER_IP}\"} ${fwd_up}"
  echo "# HELP unbound_watchdog_forward_wedge_total Cumulative forward-path wedges detected (recovered by flush_infra or restart)"
  echo "# TYPE unbound_watchdog_forward_wedge_total counter"
  echo "unbound_watchdog_forward_wedge_total{target=\"${RESOLVER_IP}\"} ${forward_wedge_total}"
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
