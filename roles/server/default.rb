# frozen_string_literal: true

# Server-side services for Linux hosts. Hardware-specific cookbooks
# (bluez, broadcom-wifi, roon-server, roon-mcp, edge-agent, zeroconf)
# stay in linux.rb because they depend on per-host hardware presence
# or cross-platform install paths; server-role daemons live here.

directory "#{node[:setup][:home]}/deploy" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

include_cookbook "samba"
include_cookbook "smartmontools"
include_cookbook "obsidian_file_sync"
include_cookbook "s3-backup"
include_cookbook "gpg-backup"
