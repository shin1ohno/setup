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
# (lxc-{cognee,hydra,memory,roon,roon-mcp}); bare-metal pro now hosts
# only physical-hardware-coupled cookbooks.
include_cookbook "arp-flux"
include_cookbook "dns-prefer-ipv4" unless node[:platform] == "darwin"
include_cookbook "bluez"
include_cookbook "zeroconf"
include_cookbook "broadcom-wifi"
include_cookbook "edge-agent"
# samba / smartmontools / obsidian_file_sync / s3-backup / gpg-backup
# now live in roles/server/default.rb

# Standalone Elastic Agent — ships system metrics + syslog/auth log to the
# 3-node ES cluster. Per-host tags = ["bare-metal"].
node.reverse_merge!(elastic_agent: { tags: ["bare-metal", "linux"] })
include_cookbook "elastic-agent"

