#!/bin/sh
# Ask homebridge-echonet-lite-plus to re-probe its knownDeviceIps.
#
# The plugin probes those IPs exactly once, at startup, and its polling loop
# then iterates only over what that probe discovered. On this LAN the aircons
# drop replies often enough that a startup probe regularly misses one — and a
# unit missed there is invisible for the whole lifetime of the process:
# unpolled, so its optional characteristics (the HomeKit temperature control
# among them) never get created, while the accessory still sits in HomeKit
# looking present. Measured 2026-07-27: after one restart the plugin held at
# "1台" across three poll cycles while both units answered a 4-EPC unicast Get
# 5/5.
#
# The plugin watches this marker file once a second and re-probes when its
# requestedAt advances — the same path its custom UI uses for "機器を再探索".
# Nudging it on a timer turns a permanent miss into a bounded one.
#
# Upstream fix would be to re-probe knownDeviceIps inside the poll loop; until
# then this is the supported external trigger.
set -eu

STORAGE=/var/lib/homebridge
MARKER="${STORAGE}/echonet-lite-plus-rediscover.json"

# Nothing to nudge if the host has not converged yet or the service is down —
# the plugin re-probes on its own start anyway.
[ -d "${STORAGE}" ] || exit 0
systemctl is-active --quiet homebridge || exit 0

printf '{"requestedAt": %s}\n' "$(date +%s%3N)" > "${MARKER}"
# The plugin deletes the marker after consuming it, so it must be able to
# unlink it as its own user.
chown homebridge:homebridge "${MARKER}" 2>/dev/null || true
