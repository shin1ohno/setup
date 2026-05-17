# frozen_string_literal: true

# Suppress AAAA lookup via /etc/resolv.conf `options no-aaaa`.
#
# Why: 192.168.1.253 (RTX1210 DNS proxy) does not return NODATA for AAAA
# records; glibc resolver waits ~5s timeout per query. AWS CLI / boto3 /
# Python requests all use dual-stack getaddrinfo and pay ~16-18s per call.
# This caused auto-mitamae-orchestrator cycles to take 15-20 min (per-LXC
# bootstrap-lxc-creds re-seed loop, each doing several AWS calls), missing
# the 5-min cron window and triggering chain-skip on flock — the fleet
# stalled with `auto_mitamae_last_apply_timestamp_seconds` stuck 49 min old.
#
# glibc 2.31+ supports `options no-aaaa` (skips AAAA query entirely).
# PVE LXC fleet + bare metal pro all run Debian 13 / glibc 2.41 — fully
# supported. Verified: `RES_OPTIONS=no-aaaa curl -sI ...sts...` 0.055s
# vs unset 15.081s (272x).
#
# Note: PVE LXCs have /etc/resolv.conf with a `# --- BEGIN PVE --- /
# # --- END PVE ---` block that PVE rewrites at CT start. The append below
# lands AFTER the END marker so the option survives CT restart.
#
# RTX root-cause fix is tracked in TODO.md "Fix RTX1210 DNS proxy AAAA
# NODATA" — once RTX returns NODATA quickly, this cookbook can be removed.
#
# Linux-only: macOS uses a different resolver stack; the symptom hasn't
# been observed there.

return if node[:platform] == "darwin"

execute "append no-aaaa option to /etc/resolv.conf" do
  command "printf 'options no-aaaa\\n' >> /etc/resolv.conf"
  user node[:setup][:system_user]
  not_if "grep -qE '^options[[:space:]].*no-aaaa' /etc/resolv.conf"
end
