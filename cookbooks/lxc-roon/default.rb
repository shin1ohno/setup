# frozen_string_literal: true
#
# lxc-roon (CT 100): Roon Server inside dedicated LXC.
#
# Bind-mounts (set up by Terraform):
#   - /opt/RoonServer (rw)
#   - /var/roon       (rw)
#   - /mnt/Media      (ro)
#
# Networking: vmbr1 with Linux bridge mode (multicast for SOOD/RAAT works).
# MAC pinning: if Roon Core license is MAC-bound (Phase 0.5-Z Z-5), the
# bare-metal pro_1 MAC is preserved via Terraform local.devices.roon.mac
# — no special handling here.

return if node[:platform] == "darwin"

# Reuse the canonical Roon Server install + systemd unit cookbook.
# It already handles: ffmpeg/cifs-utils packages, /opt/RoonServer install,
# roonserver.service unit + daemon-reload.
include_cookbook "roon-server"
