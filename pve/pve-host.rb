# frozen_string_literal: true
#
# Entry point for Proxmox VE host bootstrap.
#
# This is intentionally separate from linux.rb — the PVE host runs a tiny
# subset of cookbooks (network bridges + arp-flux + minimal tailscaled).
# All workloads (Roon, samba, docker stacks, dev workspace) live inside
# LXC guests, each running its own cookbooks/lxc-*/default.rb invoked
# via mitamae from inside the LXC after Terraform provisioning. There
# are no root-level lxc-*.rb entry points — only this file.
#
# Run after fresh PVE 9.x install (see ~/pve-auto-install/dist/pve-auto_9.1-1.iso):
#   ./bin/setup                     # Fetch mitamae binary
#   ./bin/mitamae local pve/pve-host.rb # Apply

include_recipe "../cookbooks/functions/default"

# Per-host attribute overrides. The pve-host cookbook defaults assume
# generic systemd predictable interface names; the `pro` Mac Pro 5,1
# install exposes the onboard Intel NIC pair as `nic0` (UP, used by the
# installer-created vmbr0 management bridge) and `nic1` (DOWN, claimed
# here as vmbr1's LXC service LAN parent).
node.reverse_merge!(
  pve_host: {
    service_nic: "nic1",
  }
)

include_cookbook "pve-host"

# Build /root/.ssh/authorized_keys with the public keys of every device
# in cookbooks/ssh-keys/files/devices.json. PVE host's hostname is `pro`
# (matches the existing `pro` entry, ssh_user=root) — the cookbook fetches
# /ssh-keys/devices/pro/private into /root/.ssh/pro_ed25519 and adds the
# managed-section authorized_keys entries that let every other client
# (pro-dev, air, neo, nrt, ipad, iphone) ssh in as root.
#
# Requires AWS credentials on the PVE host. The cookbook's
# require_external_auth gate skips with a warning on a fresh host
# without auth — run `aws configure --profile sh1admn` (or `aws login
# --profile sh1admn`) and re-apply.
include_cookbook "ssh-keys"

# Bare-metal hypervisor — auto-mitamae apply touches vmbr1 / arp-flux /
# ssh-keys / node-exporter, none of which write under /etc/pve. Recovery
# path on vmbr1 misconfigure is via console / IPMI; ZFS snapshot of
# rpool/ROOT/pve-1 before the first apply is the operator's pre-flight
# (zfs snapshot rpool/ROOT/pve-1@phase-3c-pre).
# Standalone Elastic Agent — ships PVE host syslog + system metrics to the
# 3-node ES cluster, tagged `pve-host` so Kibana isolates the hypervisor
# from the LXC fleet. lxc-core (node-exporter + auto-mitamae-target) runs
# first inside lxc_entry, then elastic-agent.
lxc_entry(tags: ["pve-host", "hypervisor"])

# Off-box self-heal for the CT 118 unbound LAN resolver (.61). Lives on the PVE
# host because the "active but zero replies on eth0" wedge (2026-05-31) is
# invisible to a CT-local probe; the host probes .61 over the LAN and restarts
# unbound via `pct exec`. Depends on node-exporter's textfile dir (lxc-core),
# so it runs AFTER lxc_entry.
include_cookbook "unbound-watchdog"
