# frozen_string_literal: true

include_recipe "cookbooks/functions/default"

# Bare-metal-only entry recipe. Refuse to run inside any container —
# pro-dev and similar LXC workstations should run lxc-pro-dev.rb;
# service LXCs have their own lxc-<service>.rb. The hardware cookbooks
# below (broadcom-wifi, bluez, zeroconf, edge-agent) make strong
# assumptions about kernel module access, hardware presence, and
# multi-NIC physical networking that LXC namespaces violate.
unless ENV["MITAMAE_FORCE_BARE_METAL"] == "1"
  container = run_command("systemd-detect-virt -c 2>/dev/null", error: false).stdout.strip
  if container != "" && container != "none"
    raise "linux.rb is bare-metal-only — running inside a #{container} container is not supported. " \
          "For developer LXCs use lxc-pro-dev.rb (or a sibling lxc-*-dev.rb). " \
          "For service LXCs use the matching lxc-<service>.rb. " \
          "If this is a bare-metal host that systemd-detect-virt -c misclassifies, " \
          "set MITAMAE_FORCE_BARE_METAL=1 to bypass."
  end
end

# node[:setup] is resolved once by cookbooks/host-profile (included via
# functions/default above) — no per-entry reverse_merge needed.

# Include modular roles
# Foundation: ssh keys / AWS / gh credentials FIRST, before heavy installs.
# (dirs/profile bootstrap + git + ssh + awscli + ssh-keys; homebrew is darwin-only)
include_role "foundation"
include_role "core"
include_role "programming"
include_role "llm"
include_role "extras"

# Legacy roles for backwards compatibility
include_role "manage" # Managed projects setup
include_role "network" # Network configuration
include_role "server" # Server-specific setup

# Physical-host hardware controllers. MCP servers and Roon Server / MCP
# previously included here have migrated to dedicated LXCs
# (lxc-{hydra,roon,roon-mcp}); bare-metal pro now hosts
# only physical-hardware-coupled cookbooks.
#
# Skipped on a cloud VM. Every cookbook below assumes hardware or a LAN this
# entry recipe's cloud hosts do not have, and each one is a HARD abort there
# (mitamae has no ignore_failure, so the first failure silently skips the rest
# of the run):
#   arp-flux / dns-prefer-ipv4 — multi-NIC ARP behaviour and a LAN DNS proxy;
#     dns-prefer-ipv4 also appends to a systemd-resolved-generated stub that is
#     regenerated on any DNS change, so the option is churn that silently
#     disappears
#   bluez / zeroconf — Bluetooth and mDNS have no meaning on a NAT'd VPC, and
#     standing up avahi there is an unwanted service exposure
#   broadcom-wifi — installs the bcmwl DKMS package, which cannot build against
#     a cloud kernel
#   edge-agent — needs a per-host config file that exists only for the physical
#     fleet, and rebuilds the crate from source on every apply
#   elastic-agent — enrols against the home LAN ES cluster, which is
#     unreachable, and its apt block runs privileged commands with no `user
#     root` while a cloud box applies as a non-root login user
#
# Keyed on the profile label rather than a virtualisation probe: linux.rb
# already refuses to run in a container, and a full-virt cloud VM reports
# `systemd-detect-virt -c` = none, so only the fleet table can tell these
# apart. Cloud hosts that later grow a genuine need for one of these should
# get their own entry recipe rather than a hole in this guard.
unless node[:profile][:label] == "sh1-cloud"
  include_cookbook "arp-flux"
  include_cookbook "dns-prefer-ipv4" unless node[:platform] == "darwin"
  include_cookbook "bluez"
  include_cookbook "zeroconf"
  include_cookbook "broadcom-wifi"
  include_cookbook "edge-agent::linux"
  # samba / smartmontools / obsidian_file_sync / s3-backup / gpg-backup
  # now live in roles/server/default.rb

  # Standalone Elastic Agent — ships system metrics + syslog/auth log to the
  # 3-node ES cluster. Per-host tags = ["bare-metal"].
  node.reverse_merge!(elastic_agent: { tags: ["bare-metal", "linux"] })
  include_cookbook "elastic-agent::linux"
end

# Gate visibility report — must stay the LAST include so its compile phase
# runs after every require_external_auth gate has recorded its outcome.
include_cookbook "gate-report"

