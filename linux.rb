# frozen_string_literal: true

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
include_cookbook "edge-agent"
include_cookbook "roon-mcp"
include_role "mcp-server"
# samba / smartmontools / obsidian_file_sync / s3-backup / gpg-backup
# now live in roles/server/default.rb

