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
# vmbr0 IPv6: static ULA (the address pve.home.local's AAAA publishes)
# ------------------------------------------------------------------------
# home-monitor publishes `pve.home.local AAAA -> fd97:b085:767d::10` (the v6
# counterpart of the `.10` on vmbr0). Every other host in that zone gets its
# ULA from SLAAC, so the AAAA becomes true on its own; this host is the one
# exception, and without this stanza it holds no global v6 at all:
#
#   ip -6 addr show vmbr0   -> fe80::.../64 scope link ONLY
#
# vmbr0 cannot autoconfigure it. Linux ignores RA on an interface with
# `forwarding=1` unless `accept_ra=2`, and vmbr0 has forwarding on. (vmbr1
# has forwarding off, which is why that bridge does hold SLAAC addresses,
# including one from this same /64 — see the route note below.)
#
# Publishing an AAAA nobody answers is not free. Measured 2026-08-24 from
# CT 111, curl to `pve.home.local` vs the same host by literal:
#
#   pve.home.local   connect=0.201s   <- Happy Eyeballs waits, then falls to v4
#   192.168.1.10     connect=0.0002s
#
# 200ms on EVERY connection from EVERY fleet host, because glibc does NOT
# ship RFC 6724's policy table: ULAs fall through to the ::/0 row and
# outrank IPv4, so `getent ahosts pve.home.local` returns the ULA FIRST.
# (An earlier design note here claimed the opposite — that ULA precedence 3
# loses to IPv4's 35 and internal traffic would stay on v4. That is what the
# RFC says and not what glibc does.)
#
# Static, not SLAAC-via-accept_ra=2: the address has to match what DNS
# already publishes, and a derived one would move if the NIC were replaced.
# Leaving forwarding/accept_ra alone also keeps this host's v6 egress on
# vmbr1, where its default route already lives (`proto ra`), so nothing about
# the hypervisor's own outbound path changes.
#
# Known and accepted: vmbr1 carries a SLAAC address from this same /64, so
# after this stanza two interfaces have a connected route to
# fd97:b085:767d::/64. Both NICs sit on the same L2 (192.168.1.0/24), so
# traffic still lands; the cost is that pve's SOURCE selection for ULA
# destinations may pick vmbr1's address, making those flows asymmetric.
# Inbound to ::10 always arrives on vmbr0, which is what the AAAA needs.

vmbr0_bridge  = node.dig(:pve_host, :mgmt_bridge) || "vmbr0"
vmbr0_ula     = node.dig(:pve_host, :ula) || "fd97:b085:767d::10"
vmbr0_ula_len = node.dig(:pve_host, :ula_prefix_len) || 64
vmbr0_staging = "#{node[:setup][:root]}/pve-host/vmbr0-v6"
vmbr0_system  = "/etc/network/interfaces.d/vmbr0-v6"

file vmbr0_staging do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  content <<~CFG
    # #{vmbr0_bridge} IPv6: static ULA matching pve.home.local's AAAA.
    # Managed by setup/cookbooks/pve-host. Do not edit
    # /etc/network/interfaces.d/vmbr0-v6 by hand — the next mitamae run will
    # overwrite it. The prefix is defined in home-monitor contracts
    # (devices.tf `ula_prefix_64`); change it there, not here.
    #
    # `auto #{vmbr0_bridge}` already comes from /etc/network/interfaces (the
    # PVE installer wrote it); this file only adds the inet6 family, which
    # ifupdown brings up alongside the inet stanza at boot.
    iface #{vmbr0_bridge} inet6 static
        address #{vmbr0_ula}/#{vmbr0_ula_len}
  CFG
end

execute "install vmbr0 IPv6 ifupdown drop-in" do
  command "sudo install -m 644 -o root -g root #{vmbr0_staging} #{vmbr0_system}"
  not_if "diff -q #{vmbr0_staging} #{vmbr0_system} 2>/dev/null"
  notifies :run, "execute[add vmbr0 ULA]"
end

# Applied live rather than via `ifup`: vmbr0 is already up (it carries this
# host's management IPv4), and `ifup vmbr0` on an up interface fails instead
# of adding the new family. The drop-in above is what makes it survive a
# reboot; this is what makes it true now. Guarded on the address itself, so
# it is a no-op once present.
execute "add vmbr0 ULA" do
  command "sudo ip -6 addr add #{vmbr0_ula}/#{vmbr0_ula_len} dev #{vmbr0_bridge}"
  action :nothing
  not_if "ip -6 addr show #{vmbr0_bridge} 2>/dev/null | grep -q '#{vmbr0_ula}/'"
end

# ------------------------------------------------------------------------
# Resolver order (/etc/resolv.conf)
# ------------------------------------------------------------------------
# The host's resolv.conf predates the unbound LAN resolver (CT 118 / .61,
# cookbooks/unbound) that replaced the RTX1210 forwarder: it listed the RTX
# proxy (.253) first and a PUBLIC resolver (1.1.1.1) as the only fallback.
# That pairing loses the whole host's telemetry whenever the RTX stops
# answering :53 — observed 2026-08-12 (self-heal #855/#856/#857):
#
#   1. The RTX kept routing (ping OK, gateway fine) but stopped answering
#      UDP/53, so every lookup fell through to 1.1.1.1.
#   2. 1.1.1.1 is authoritative-negative for the private `home.local` zone,
#      so `es-0.home.local` came back NXDOMAIN — "no such host" instead of
#      "resolver unavailable". elastic-agent treats that as permanent:
#      `Exporting failed. Dropping data` / `Drop batch`, unbuffered. pro's
#      metrics stopped fleet-wide (11.5 min from 09:12Z, 22 min from
#      09:41Z), and the Kibana es-query rule "Document count is 0 in the
#      last 10m" then fired one false "Process down" per process.
#
# So the public resolver is dropped on purpose, not merely reordered: it can
# never answer home.local, and its only effect there is to turn a retryable
# timeout into a permanent NXDOMAIN. unbound leads (it serves home.local
# locally plus TCP/53, and forwards everything else to Cloudflare DoT), which
# is the order the RTX already hands DHCP clients — home-monitor/rtx-hnd.tf
# `dns_servers = [dns-resolver, vpc_resolver, 1.1.1.1]`.
#
# The RTX secondary is dropped here too, and for a stronger reason than the
# public resolver was: it does not answer DNS AT ALL any more. Probed
# 2026-08-21 from this host and from CT 104, both on the LAN — A and AAAA
# both time out and TCP/53 is refused outright, while ICMP and TCP/22 to the
# same address are healthy, so the box is up and only the resolver is gone:
#
#   dig @192.168.1.253 example.com A      -> timed out (6s)
#   </dev/tcp/192.168.1.253/53            -> Connection refused
#   ping 192.168.1.253                    -> 0% loss, 0.147ms
#
# A black-holed secondary is worse than no secondary: it cannot answer, and
# glibc still pays the full per-query timeout walking to it before failing.
# unbound is therefore the sole entry until it can be paired with its own
# IPv6 address (a stable ULA is being introduced separately) — that gives a
# real second path to the same daemon over a different transport, whereas
# 1.1.1.1 could only ever turn a retryable home.local timeout into a
# permanent NXDOMAIN. unbound-watchdog (included from pve-host.rb) remains
# the recovery mechanism for a wedged unbound.
#
# The file is written whole rather than appended so the nameserver list stays
# converged. It carried `options no-aaaa` for the same reason until
# 2026-08-21; that option is now removed fleet-wide by
# cookbooks/resolv-options, which explains the history in full.
#
# Override per host via node[:pve_host][:nameservers] / [:dns_search] when
# adding a 2nd PVE node on a different LAN.

resolv_staging = "#{node[:setup][:root]}/pve-host/resolv.conf"
resolv_system  = "/etc/resolv.conf"
nameservers    = node.dig(:pve_host, :nameservers) || ["192.168.1.61"]
dns_search     = node.dig(:pve_host, :dns_search) || "home.local"

# Built by joining lines rather than a squiggly heredoc: the nameserver list is
# variable-length, and a multi-line interpolation inside <<~ is dedented from
# the literal source lines only, so the 2nd and later entries would land at
# column 0 by accident rather than by intent.
resolv_content = [
  "# Managed by setup/cookbooks/pve-host. Do not edit /etc/resolv.conf by",
  "# hand - the next mitamae run will overwrite it.",
  "search #{dns_search}",
]
nameservers.each { |ns| resolv_content << "nameserver #{ns}" }

file resolv_staging do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  content "#{resolv_content.join("\n")}\n"
end

# /etc/resolv.conf is 0644, so the diff guard is readable by the non-root
# apply user (~/ManagedProjects/setup/.claude/rules/ruby.md "Guard must be evaluatable under mitamae's actual
# runtime privilege"). No resolver daemon owns the file on this host —
# systemd-resolved / networkd / NetworkManager are all inactive and both
# bridges are `inet static`, so nothing regenerates it behind us.
execute "install /etc/resolv.conf (unbound first, no public fallback)" do
  command "sudo install -m 644 -o root -g root #{resolv_staging} #{resolv_system}"
  not_if "diff -q #{resolv_staging} #{resolv_system} 2>/dev/null"
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

# ------------------------------------------------------------------------
# TUN device passthrough for LXCs running tailscaled
# ------------------------------------------------------------------------
# tailscaled requires /dev/net/tun. Unprivileged LXCs by default cannot
# access /dev — the cgroup device whitelist + mount entry below punches a
# specific hole for the TUN char device (major 10 minor 200). Without
# this, tailscaled fails with "Failed to start tun ... operation not
# permitted" or silently produces a degraded mode where peer routes
# don't install.
#
# CT IDs default to the tailscale-running LXCs in
# home-monitor/pve-lxcs.tf (pro-router=102, pro-dev=104). Override per
# host via node[:pve_host][:tun_ctids] when adding more or running on a
# 2nd PVE node. Existing manual entries (matching the literal
# `lxc.cgroup2.devices.allow: c 10:200 rwm` line) are detected by the
# not_if guard and skipped — no duplicate writes.
#
# The LXC reboot only fires via `notifies` when the file was actually
# modified, so steady-state mitamae runs are no-ops. On a fresh-rebuild
# pass (TF creates LXC → pve-host mitamae adds TUN → LXC reboot), the
# notify chain converges in one apply.

tun_ctids = node.dig(:pve_host, :tun_ctids) || [102, 104]

tun_ctids.each do |vmid|
  conf_path = "/etc/pve/lxc/#{vmid}.conf"

  execute "inject TUN passthrough in #{conf_path}" do
    command <<~CMD
      sudo tee -a #{conf_path} > /dev/null <<'EOF'

      # BEGIN tun-managed-by-mitamae
      lxc.cgroup2.devices.allow: c 10:200 rwm
      lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
      # END tun-managed-by-mitamae
      EOF
    CMD
    only_if "test -f #{conf_path}"
    not_if "grep -qE 'tun-managed-by-mitamae|lxc\\.cgroup2\\.devices\\.allow:.*c 10:200 rwm' #{conf_path}"
    notifies :run, "execute[restart LXC #{vmid} to pick up TUN config]"
  end

  # `pct stop` returns non-zero on already-stopped CTs; suppress and
  # always `pct start` afterwards. The 2 s sleep gives kernel namespace
  # teardown time before re-creating.
  execute "restart LXC #{vmid} to pick up TUN config" do
    command "sudo pct stop #{vmid} 2>/dev/null; sleep 2; sudo pct start #{vmid}"
    action :nothing
  end
end
