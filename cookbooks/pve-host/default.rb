# frozen_string_literal: true
#
# pve-host: Proxmox VE host minimal config + 2 Linux bridges + Pattern 1
# break-glass tailscaled.
#
# Scope: runs on the PVE host itself (Debian 13 / Trixie), NOT on LXC guests.
# The cookbook is invoked via `pve-host.rb` (sibling to linux.rb), not from
# linux.rb. Daemons that belong inside LXCs (Roon, samba, docker stacks)
# stay out of this recipe — pve-host's only job is to be a minimal hypervisor.
#
# References (from frolicking-beaming-crescent.md Phase 2 + Phase 9):
#   - arp-flux cookbook (B6, mandatory on multi-NIC PVE host)
#   - 2 Linux bridges (vmbr0 = enp25s0 management, vmbr1 = enp12s0 LXC service LAN)
#   - Pattern 1 break-glass tailscaled with tag:emergency-admin
#     (subnet route advertise lives on pro-router LXC, not host)

return if node[:platform] == "darwin"

# Proxmox VE only — guard against accidental run on plain Debian.
# /etc/pve is the canonical PVE marker (mounted by pve-cluster).
unless File.directory?("/etc/pve")
  MItamae.logger.warn("pve-host: /etc/pve not found — host does not appear to be a Proxmox VE node")
  MItamae.logger.warn("If this is intentional (testing on plain Debian), comment out the directory check.")
  return
end

# Multi-NIC ARP-flux suppression. Without this, host kernel default arp_ignore=0
# lets sibling NICs answer DHCP ACD probes, which on rotation forces lease
# release — IP renumbering observed historically. Mandatory on PVE host.
include_cookbook "arp-flux"

# ------------------------------------------------------------------------
# Network: 2 Linux bridges (vmbr0 = mgmt, vmbr1 = LXC service)
# ------------------------------------------------------------------------
# vmbr0 is created by the PVE installer (auto-bridge over the management
# NIC chosen at install). We add vmbr1 as a sibling bridge over enp12s0
# so foundation LXCs (pro-router / roon / samba / pro-dev) get an
# independent broadcast domain. bridge-stp off keeps performance up; the
# arp-flux cookbook handles the multi-NIC same-subnet hazard.
#
# We use ifupdown (PVE's native /etc/network/interfaces) instead of
# systemd-networkd. Drop-in style: a separate file under
# /etc/network/interfaces.d/ that the main /etc/network/interfaces loads
# via `source /etc/network/interfaces.d/*` (default in Debian).

vmbr1_staging = "#{node[:setup][:root]}/pve-host/vmbr1"
vmbr1_system  = "/etc/network/interfaces.d/vmbr1"

# Service NIC for vmbr1. Default enp12s0 matches the original PVE host
# build; PVE hosts with different NIC naming must override via
# node[:pve_host][:service_nic].
service_nic = node.dig(:pve_host, :service_nic) || "enp12s0"

directory "#{node[:setup][:root]}/pve-host" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

file vmbr1_staging do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  content <<~CFG
    # vmbr1: LXC service LAN bridge over #{service_nic}
    # Managed by setup/cookbooks/pve-host. Do not edit /etc/network/interfaces.d/vmbr1
    # by hand — the next mitamae run will overwrite it.
    auto #{service_nic}
    iface #{service_nic} inet manual

    auto vmbr1
    iface vmbr1 inet manual
        bridge-ports #{service_nic}
        bridge-stp off
        bridge-fd 0
  CFG
end

execute "install vmbr1 ifupdown drop-in" do
  command "sudo install -m 644 -o root -g root #{vmbr1_staging} #{vmbr1_system}"
  not_if "diff -q #{vmbr1_staging} #{vmbr1_system} 2>/dev/null"
  notifies :run, "execute[bring up vmbr1]"
end

execute "bring up vmbr1" do
  command "sudo ifup vmbr1"
  action :nothing
  not_if "ip link show vmbr1 2>/dev/null | grep -q 'state UP'"
end

# ------------------------------------------------------------------------
# Data disk mounts: sdb (Media) and sdc (data)
# ------------------------------------------------------------------------
# These external ext4 disks survived the auto-install untouched (the ZFS
# rpool was size-filtered to the ~932 GB SSD only). Mount them at boot so
# LXC bind-mounts (created by Terraform) have valid sources.
#
# Defaults match the `pro` Mac Pro 5,1 layout. UUIDs are stable across
# the reinstall because the ext4 superblock was preserved. Override per
# host via node[:pve_host][:data_mounts] when adding a 2nd PVE node.
#
# `nofail` lets boot proceed if a disk is missing; `device-timeout=10s`
# bounds the wait so a flaky cable doesn't hang systemd's local-fs.target.

data_mounts = node.dig(:pve_host, :data_mounts) || [
  {
    path: "/mnt/Media",
    uuid: "cceb11bc-9685-4932-aa2d-660b0827a2c5", # sdb1, 3.6 TB
    fstype: "ext4",
    options: "defaults,nofail,x-systemd.device-timeout=10s",
  },
  {
    path: "/mnt/data",
    uuid: "0a85e7ba-b61f-4f84-bef8-8101a760c82b", # sdc1, 1.8 TB
    fstype: "ext4",
    options: "defaults,nofail,x-systemd.device-timeout=10s",
  },
]

data_mounts.each do |m|
  fstab_line = "UUID=#{m[:uuid]} #{m[:path]} #{m[:fstype]} #{m[:options]} 0 2"

  execute "create mountpoint #{m[:path]}" do
    command "sudo install -d -m 755 -o root -g root #{m[:path]}"
    not_if "test -d #{m[:path]}"
  end

  execute "add #{m[:path]} to /etc/fstab" do
    # printf via sudo tee -a for atomic append. grep guard makes the
    # resource idempotent regardless of which form (UUID= or path) the
    # operator may have hand-edited in a prior run.
    command %(printf '%s\\n' '#{fstab_line}' | sudo tee -a /etc/fstab >/dev/null)
    not_if "grep -qE '#{m[:uuid]}|[[:space:]]#{m[:path]}[[:space:]]' /etc/fstab"
  end

  execute "mount #{m[:path]}" do
    command "sudo mount #{m[:path]}"
    not_if "mountpoint -q #{m[:path]}"
  end
end

# ------------------------------------------------------------------------
# Pattern 1 break-glass tailscaled (tag:emergency-admin only)
# ------------------------------------------------------------------------
# Subnet route advertise + AWS VPC tunnel live on the pro-router LXC.
# The PVE host runs a *minimal* tailscaled solely as an out-of-home
# rescue path: from a tagged-trusted-admin device we can SSH directly
# to the hypervisor (port 22) without going through pro-router.
# `--advertise-routes=` is intentionally absent. PVE Web UI 8006 is NOT
# opened via tailnet ACL (see home-monitor/tailscale-acl.tf).
#
# Install via the standard Tailscale apt repo (same as `cookbooks/tailscale`
# uses for non-darwin), but skip `tailscale up` here — the operator runs
# it interactively post-bootstrap with a one-off auth key + tag flag.

remote_file "#{node[:setup][:root]}/pve-host/tailscale-install.sh" do
  source "files/tailscale-install.sh"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

execute "install tailscale on PVE host" do
  command "sudo bash #{node[:setup][:root]}/pve-host/tailscale-install.sh"
  not_if "command -v tailscale >/dev/null 2>&1"
end

# Operator hint when tailscale isn't authenticated yet.
local_ruby_block "log tailscale auth hint" do
  block do
    state = `tailscale status --json 2>/dev/null`
    if state.empty? || state.include?('"BackendState":"NeedsLogin"')
      MItamae.logger.warn(<<~MSG)
        pve-host: tailscaled installed but not authenticated. Run:
          sudo tailscale up \\
            --auth-key=$(aws ssm get-parameter --name /tailscale/pve-host-auth-key --with-decryption --query Parameter.Value --output text) \\
            --advertise-tags=tag:emergency-admin \\
            --hostname=pve \\
            --ssh
      MSG
    end
  end
end

# Apply the same tailscale resolvconf workaround as cookbooks/tailscale.
# Trixie keeps the systemd-resolved resolvconf shim that tailscaled mishandles.
execute "divert systemd-resolved resolvconf shim for tailscale DirectManager" do
  command "sudo dpkg-divert --local --rename --add /usr/sbin/resolvconf"
  only_if "test -L /usr/sbin/resolvconf && dpkg -S /usr/sbin/resolvconf 2>/dev/null | grep -q '^systemd-resolved:'"
  not_if "dpkg-divert --list /usr/sbin/resolvconf 2>/dev/null | grep -q 'local diversion of /usr/sbin/resolvconf'"
  notifies :run, "execute[restart tailscaled after resolvconf divert (pve)]"
end

execute "restart tailscaled after resolvconf divert (pve)" do
  command "sudo systemctl restart tailscaled"
  only_if "systemctl is-active --quiet tailscaled"
  action :nothing
end
