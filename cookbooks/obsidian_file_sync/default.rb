# frozen_string_literal: true
#
# Cookbook for setting up Obsidian vault file synchronization
# Uses rclone to sync Obsidian vault files between devices

# Ensure rclone is installed as a dependency
include_cookbook "rclone"

# Create base sync directory for Obsidian vaults
directory "#{ENV['HOME']}/obsidian" do
  owner node[:setup][:user]
  mode "755"
end

# Create config directory for sync scripts
directory "#{node[:setup][:root]}/obsidian_sync" do
  owner node[:setup][:user]
  mode "755"
end

# Create the sync script
file "#{node[:setup][:root]}/obsidian_sync/sync.sh" do
  owner node[:setup][:user]
  mode "755"
  content <<-EOM
#!/bin/bash
# Obsidian Vault Sync Script using rclone

# Configuration
SOURCE_DIR="${HOME}/obsidian"
REMOTE_NAME="icloud"
REMOTE_PATH="Obsidian"
LOG_FILE="${HOME}/.setup_shin1ohno/obsidian_sync/sync.log"

# Log function
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Check if rclone is installed
if ! command -v rclone &> /dev/null; then
  log "ERROR: rclone is not installed. Please install it first."
  exit 1
fi

# Check if rclone remote exists, if not provide setup instructions
if ! rclone listremotes | grep -q "^${REMOTE_NAME}:"; then
  log "Remote '${REMOTE_NAME}:' not found. Please set up your remote first."
  log "Run: rclone config"
  log "Example setup for Google Drive:"
  log "1. n (new remote)"
  log "2. Name it '${REMOTE_NAME}'"
  log "3. Choose your storage provider (like 'drive' for Google Drive)"
  log "4. Follow the prompts to authorize access"
  exit 1
fi

# Create source directory if it doesn't exist
if [ ! -d "$SOURCE_DIR" ]; then
  log "Creating source directory: $SOURCE_DIR"
  mkdir -p "$SOURCE_DIR"
fi

# Sync function with bidirectional sync
sync_obsidian() {
  log "Starting bidirectional sync of Obsidian vault"
  rclone bisync "${REMOTE_NAME}:${REMOTE_PATH}" "$SOURCE_DIR" --verbose --create-empty-src-dirs --exclude ".obsidian/workspace.json" --exclude ".trash/**" 2>&1 | tee -a "$LOG_FILE"
  
  log "Sync completed"
}

# Main execution
log "======= Obsidian Vault Sync Started ======="
sync_obsidian
log "======= Obsidian Vault Sync Finished ======="
EOM
  not_if "test -f #{node[:setup][:root]}/obsidian_sync/sync.sh"
end

# Create a README file with usage instructions
file "#{node[:setup][:root]}/obsidian_sync/README.md" do
  owner node[:setup][:user]
  mode "644"
  content <<-EOM
# Obsidian Vault Sync

This script synchronizes your Obsidian vault between devices using rclone.

## Setup Instructions

1. Make sure rclone is installed and configured:
   ```
   rclone config
   ```
   
2. Create a new remote named "obsidian" pointing to your preferred cloud storage:
   - For Google Drive, select "drive" as the type
   - For Dropbox, select "dropbox" as the type
   - Follow the prompts to authorize access

3. To run a manual sync:
   ```
   #{node[:setup][:root]}/obsidian_sync/sync.sh
   ```

4. Logs are stored in:
   ```
   #{node[:setup][:root]}/obsidian_sync/sync.log
   ```

## Customization

Edit the sync script to change:
- Sync directory: Change SOURCE_DIR in the script
- Remote name: Change REMOTE_NAME in the script

## Troubleshooting

If you encounter issues:
1. Check the log file for errors
2. Verify your rclone configuration with `rclone config`
3. Test connectivity with `rclone ls obsidian:`
EOM
  not_if "test -f #{node[:setup][:root]}/obsidian_sync/README.md"
end
