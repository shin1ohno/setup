# frozen_string_literal: true

include_recipe "cookbooks/functions/default"

user = ENV["USER"]
group = `id -gn`.strip
node.reverse_merge!(
  setup: {
    root: "#{ENV["HOME"]}/.setup_shin1ohno",
    user: user,
    group: group,
    system_user: "root",
    system_group: "root",
  }
)

# Include modular roles
include_role "core"
include_role "programming"
include_role "llm"
include_role "extras"

# Legacy roles for backwards compatibility
include_role "manage" # Managed projects setup
include_role "network" # Network configuration
include_role "server" # Server-specific setup

include_cookbook "bluez"
include_cookbook "zeroconf"
include_cookbook "broadcom-wifi"
include_cookbook "roon-server"
include_cookbook "docker-engine"
include_cookbook "samba"
include_cookbook "smartmontools"
include_cookbook "obsidian_file_sync"
include_cookbook "s3-backup"
