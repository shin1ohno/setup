# frozen_string_literal: true

# Common base role for every PVE LXC entry recipe (pve/lxc-*.rb) and the
# bare-metal PVE host (pve/pve-host.rb). Bundles the two primitives that
# every host in the auto-mitamae fleet needs.
#
# - node-exporter: Prometheus scrape target on :9100. Scraped by the
#   monitoring LXC (CT 111, 192.168.1.76) — see
#   cookbooks/lxc-monitoring/files/prometheus.yml `node-*` jobs. Same
#   cookbook used uniformly across the fleet (LXC guests + PVE host).
# - auto-mitamae-target: receiver-side of the centralised auto-apply
#   system. Installs the forced-command authorized_keys entry that the
#   orchestrator on the monitoring LXC uses to SSH-push `mitamae local
#   <role>` runs. Replaces the deprecated Phase 1 per-host systemd timer.
#
# Add a primitive here only if it applies to ALL hosts in this role pool.
# Host-specific primitives (docker-engine, awscli, tailscale, ssh-keys)
# stay in pve/lxc-X.rb or pve/pve-host.rb.

include_cookbook "node-exporter"
include_cookbook "auto-mitamae-target"
