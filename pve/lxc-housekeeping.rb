# frozen_string_literal: true
#
# Entry recipe for the housekeeping LXC (CT 103): personal sync isolation —
# s3-backup (sensitive files → S3 GPG-encrypted) + obsidian_file_sync
# (rclone → iCloud, every 15 min). Isolated from the MCP service stack so
# backup failures or rclone issues don't impact the OAuth chain.
#
# Bind-mount (set up by Terraform):
#   - /mnt/data/obsidian-vault (rw, optional — vault 実体が sdc にあるため)
#
# RAM 512 MiB / CPU 1. Runs as user (systemd --user timers).
#
# Run inside the LXC after the Terraform layer has provisioned it:
#   apt-get install -y git curl ca-certificates sudo
#   git clone https://github.com/shin1ohno/setup.git /root/setup
#   cd /root/setup && ./bin/setup
#   ./bin/mitamae local pve/lxc-housekeeping.rb

include_recipe "../cookbooks/functions/default"

include_cookbook "s3-backup"
include_cookbook "obsidian_file_sync"
lxc_entry(tags: ["lxc", "housekeeping"])
