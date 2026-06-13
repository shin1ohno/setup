# frozen_string_literal: true
#
# Entry recipe for the pro-router LXC (CT 102): Tailscale subnet route
# advertise + AWS VPC tunnel (Pattern 2 main path).
#
# Per migration plan (frolicking-beaming-crescent.md Phase 3a):
#   - tag:home-router (advertises 192.168.1.0/24 to tailnet)
#   - AWS VPC tunnel peer receiving from nrt-subnet-router
#   - Pattern 2 main path (Pattern 1 break-glass lives on PVE host)
#
# RAM 256 MiB / CPU 1 / vmbr1.
#
# pro-router runs Tailscale subnet-router only — it is NOT the LAN
# gateway, so a misconfigured auto-mitamae apply only breaks the
# Tailscale advertise path; LAN-internal connectivity to the monitoring
# LXC stays via `pct exec` from the PVE host. Recovery path is intact.
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-pro-router.rb
#
# `tailscale up` is intentionally not part of this recipe — auth-key
# fetch + tag flag is an operator step (see log_warn hint in the cookbook).
#
# Service logic lives in cookbooks/lxc-pro-router (Phase 4 extraction). This
# entry stays thin: include the cookbook, then the lxc-core + elastic-agent tail.

include_recipe "../cookbooks/functions/default"

include_cookbook "lxc-pro-router"
lxc_entry(tags: ["lxc", "pro-router", "tailscale"])
