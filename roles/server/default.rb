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

# samba exports a LAN file share (declaring a media path that exists only on
# the physical fleet) and smartmontools monitors physical disk SMART data.
# Neither is meaningful on a cloud VM, and standing up smbd/nmbd on one is an
# unwanted service exposure rather than a no-op — so skip both there instead of
# relying on `deb-systemd-invoke … || true` to swallow the service-start
# failure. The remaining three are pure file/directory writes and stay.
unless node[:profile][:label] == "sh1-cloud"
  include_cookbook "samba"
  include_cookbook "smartmontools"
end

include_cookbook "obsidian_file_sync"
include_cookbook "s3-backup"
# Static ::linux — this role is included from linux.rb alone, so it names the
# per-OS recipe rather than dispatching. darwin.rb includes gpg-backup::darwin
# directly; that half also ships the macOS Keychain tool.
include_cookbook "gpg-backup::linux"
