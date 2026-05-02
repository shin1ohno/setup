# frozen_string_literal: true
#
# lxc-samba (CT 101): SMB share for [Media] read-only.
#
# Bind-mount (set up by Terraform):
#   - /mnt/Media (ro)
#
# Networking: vmbr1 (NetBIOS / mDNS need broadcast on LAN).
# RAM 256 MiB / CPU 1.

return if node[:platform] == "darwin"

include_cookbook "samba-server"
