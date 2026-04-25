# frozen_string_literal: true
#
# Cookbook for mounting S3 ingest-drop bucket via rclone
# All machines share ~/ingest/drop/ backed by s3://ingest-drop-hm2024
# On the home server, ~/ingest/drop/ may be a symlink to the cognee
# processing directory — the mount script resolves this automatically.

include_cookbook "rclone"
include_cookbook "awscli"

config_dir = "#{node[:setup][:root]}/ingest-drop"
rclone_conf = "#{config_dir}/rclone.conf"
mount_point = "#{node[:setup][:home]}/ingest/drop"
mount_script = "#{config_dir}/mount.sh"
generate_script = File.join(File.dirname(__FILE__), "files", "generate_rclone_conf.sh")

directory config_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# ~/ingest/ parent directory (only if not a symlink)
directory "#{node[:setup][:home]}/ingest" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  not_if "test -L #{node[:setup][:home]}/ingest"
end

# ~/ingest/drop/ (only if not a symlink — home server has a symlink to cognee)
directory mount_point do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  not_if "test -L #{mount_point} || test -L #{node[:setup][:home]}/ingest"
end

remote_file mount_script do
  source "files/mount.sh"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# Generate rclone config from SSM. Gated by AWS auth on first run; on warm
# re-runs the existence check short-circuits the prompt + the execute.
require_external_auth(
  tool_name: "AWS CLI (for /ingest/drop/* SSM params)",
  check_command: "aws sts get-caller-identity",
  instructions: "On a fresh machine: aws configure (or aws configure --profile <name> + export AWS_PROFILE=<name>). Then press Enter to retry.",
  skip_if: -> { File.exist?(rclone_conf) },
) do
  execute "generate ingest-drop rclone config" do
    command "bash #{generate_script} #{rclone_conf}"
    user node[:setup][:user]
  end
end

if node[:platform] == "darwin"
  # macOS: launchd user agent for persistent rclone mount
  directory "#{node[:setup][:home]}/Library/LaunchAgents" do
    owner node[:setup][:user]
    mode "755"
  end

  file "#{node[:setup][:home]}/Library/LaunchAgents/com.#{node[:setup][:user]}.ingest-drop.plist" do
    owner node[:setup][:user]
    mode "644"
    content <<-EOM
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.#{node[:setup][:user]}.ingest-drop</string>
    <key>ProgramArguments</key>
    <array>
        <string>#{mount_script}</string>
        <string>#{rclone_conf}</string>
        <string>#{mount_point}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>#{config_dir}/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>#{config_dir}/stderr.log</string>
</dict>
</plist>
EOM
    not_if "test -f #{node[:setup][:home]}/Library/LaunchAgents/com.#{node[:setup][:user]}.ingest-drop.plist"
  end

  execute "load ingest-drop launchd job" do
    command "launchctl load #{node[:setup][:home]}/Library/LaunchAgents/com.#{node[:setup][:user]}.ingest-drop.plist"
    only_if "test -f #{rclone_conf}"
    not_if "launchctl list | grep com.#{node[:setup][:user]}.ingest-drop"
  end
else
  # Enable linger so systemd user services survive logout
  execute "enable loginctl linger for #{node[:setup][:user]}" do
    command "sudo loginctl enable-linger #{node[:setup][:user]}"
    only_if "which loginctl"
    not_if "test -f /var/lib/systemd/linger/#{node[:setup][:user]}"
  end

  # Linux: systemd user service for persistent rclone mount
  directory "#{node[:setup][:home]}/.config/systemd/user" do
    owner node[:setup][:user]
    mode "755"
  end

  file "#{node[:setup][:home]}/.config/systemd/user/ingest-drop.service" do
    owner node[:setup][:user]
    mode "644"
    content <<-EOM
[Unit]
Description=Mount ingest-drop S3 bucket via rclone
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=#{mount_script} #{rclone_conf} #{mount_point}
ExecStop=/bin/fusermount -u #{mount_point}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOM
    not_if "test -f #{node[:setup][:home]}/.config/systemd/user/ingest-drop.service"
  end

  execute "enable ingest-drop mount service" do
    command "systemctl --user daemon-reload && systemctl --user enable ingest-drop.service && systemctl --user start ingest-drop.service"
    only_if "systemctl --user status >/dev/null 2>&1"
    only_if "test -f #{rclone_conf}"
    not_if "systemctl --user is-active ingest-drop.service"
  end
end
