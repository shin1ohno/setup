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
#   ./bin/mitamae local pve-host.rb # Apply

include_recipe "cookbooks/functions/default"

user = ENV["USER"]
group = `id -gn`.strip
node.reverse_merge!(
  setup: {
    home: ENV["HOME"],
    root: "#{ENV["HOME"]}/.setup_shin1ohno",
    user: user,
    group: group,
    system_user: "root",
    system_group: "root",
  }
)

include_cookbook "pve-host"
