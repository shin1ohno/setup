# frozen_string_literal: true
#
# lxc-housekeeping (CT 103): personal sync isolation
#   - s3-backup (sensitive files → S3 GPG encrypted)
#   - obsidian_file_sync (rclone → iCloud, every 15 min)
#
# Bind-mount (set up by Terraform):
#   - /mnt/data/obsidian-vault (rw, optional — vault実体が sdc にあるため)
#
# Per migration plan rationale: primary use case "personal data sync" is
# isolated from MCP service stack so backup failures or rclone issues
# don't impact the OAuth chain.
#
# RAM 512 MiB / CPU 1. Runs as user (systemd --user timers).

return if node[:platform] == "darwin"

# Reuse existing cookbooks for the actual work. They are already
# well-tested on bare-metal pro and don't need LXC-specific changes.
include_cookbook "s3-backup"
include_cookbook "obsidian_file_sync"
