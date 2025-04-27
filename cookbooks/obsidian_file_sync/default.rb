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
  rclone bisync "$SOURCE_DIR" "${REMOTE_NAME}:${REMOTE_PATH}" --create-empty-src-dirs --exclude ".obsidian/workspace.json" --exclude ".trash/**" 2>&1 | tee -a "$LOG_FILE"
  
  log "Sync completed"
}

# Main execution
log "======= Obsidian Vault Sync Started ======="
sync_obsidian
log "======= Obsidian Vault Sync Finished ======="
EOM
  not_if "test -f #{node[:setup][:root]}/obsidian_sync/sync.sh"
end

# Create systemd user service and timer if on Linux (non-macOS)
if node[:platform] != "darwin"
  directory "#{ENV['HOME']}/.config/systemd/user" do
    owner node[:setup][:user]
    mode "755"
  end

  # Create the systemd service
  file "#{ENV['HOME']}/.config/systemd/user/obsidian-sync.service" do
    owner node[:setup][:user]
    mode "644"
    content <<-EOM
[Unit]
Description=Obsidian Vault Synchronization Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=#{node[:setup][:root]}/obsidian_sync/sync.sh

[Install]
WantedBy=default.target
EOM
    not_if "test -f #{ENV['HOME']}/.config/systemd/user/obsidian-sync.service"
  end

  # Create the systemd timer
  file "#{ENV['HOME']}/.config/systemd/user/obsidian-sync.timer" do
    owner node[:setup][:user]
    mode "644"
    content <<-EOM
[Unit]
Description=Run Obsidian sync periodically

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOM
    not_if "test -f #{ENV['HOME']}/.config/systemd/user/obsidian-sync.timer"
  end

  # Enable and start the timer
  execute "enable obsidian sync timer" do
    command "systemctl --user daemon-reload && systemctl --user enable obsidian-sync.timer && systemctl --user start obsidian-sync.timer"
    only_if "which systemctl"
    only_if "test -f #{ENV['HOME']}/.config/systemd/user/obsidian-sync.timer"
  end
else
  # Create launchd plist on macOS
  directory "#{ENV['HOME']}/Library/LaunchAgents" do
    owner node[:setup][:user]
    mode "755"
  end

  file "#{ENV['HOME']}/Library/LaunchAgents/com.shin1ohno.obsidian-sync.plist" do
    owner node[:setup][:user]
    mode "644"
    content <<-EOM
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.shin1ohno.obsidian-sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>#{node[:setup][:root]}/obsidian_sync/sync.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>900</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>#{node[:setup][:root]}/obsidian_sync/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>#{node[:setup][:root]}/obsidian_sync/stderr.log</string>
</dict>
</plist>
EOM
    not_if "test -f #{ENV['HOME']}/Library/LaunchAgents/com.shin1ohno.obsidian-sync.plist"
  end

  # Load the launchd job
  execute "load obsidian sync launchd job" do
    command "launchctl load #{ENV['HOME']}/Library/LaunchAgents/com.shin1ohno.obsidian-sync.plist"
    only_if "which launchctl"
    not_if "launchctl list | grep com.shin1ohno.obsidian-sync"
  end
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

3. The sync is configured to run automatically:
   - On Linux: Every 15 minutes via systemd timer
   - On macOS: Every 15 minutes via launchd

4. To run a manual sync:
   ```
   #{node[:setup][:root]}/obsidian_sync/sync.sh
   ```

5. Logs are stored in:
   ```
   #{node[:setup][:root]}/obsidian_sync/sync.log
   ```

## Customization

Edit the sync script to change:
- Sync frequency: Edit the timer/launchd configuration
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
