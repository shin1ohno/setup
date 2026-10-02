# frozen_string_literal: true
#
# mac-block-tracker — keeps ann's Mac inside the rtx-hnd MAC block when macOS
# rotates its Private Wi-Fi Address (2026-09-30: the MAC changed and the block
# silently stopped matching for two nights).
#
# A systemd timer runs files/mac-block-tracker.sh every 5 minutes. It finds the
# Mac by its AirPlay `pi` over unicast mDNS, and when the Mac's MAC differs
# from the SSM slot /home-monitor/mac-blocks/ann/slot it rewrites rtx-hnd
# filters 17/18, reads them back, updates the slot and mails
# home-monitoring-alerts. home-monitor (mac-block-tracker.tf) declares the
# slot, the filters and the IAM user this job runs as.
#
# pro-dev ONLY (hostname-guarded): it reaches the LAN for mDNS and the router.
#
# Credential: the mac-block-tracker IAM user can read the router's admin
# password, so its key is NOT made readable to pve-bootstrap-ssm (which every
# LXC holds). It is fetched once with the operator's sh1admn profile, the same
# way /linear-probe/* is, into /etc/mac-block-tracker/aws.env (root:group
# 0640). On the unattended auto-mitamae path sh1admn is absent, the gate skips
# with a warning, and the file already in place is left alone.

detected_hostname = run_command("hostname -s", error: false).stdout.strip
unless detected_hostname == "pro-dev"
  MItamae.logger.warn(
    "mac-block-tracker: host '#{detected_hostname}' is not pro-dev — skipping.",
  )
  return
end

tracker_user = "mac-block-tracker"
aws_profile  = "sh1admn"
aws_region   = "ap-northeast-1"
libexec_dir  = "/usr/local/libexec/mac-block-tracker"
etc_dir      = "/etc/mac-block-tracker"
env_path     = "#{etc_dir}/aws.env"
staging_dir  = "#{node[:setup][:root]}/mac-block-tracker"

install_package "dnsutils" do
  ubuntu "bind9-dnsutils"
end

execute "create #{tracker_user} system user" do
  command "sudo useradd --system --no-create-home --shell /usr/sbin/nologin #{tracker_user}"
  not_if "id -u #{tracker_user} >/dev/null 2>&1"
end

directory node[:setup][:root] do
  mode "755"
end

directory staging_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

execute "create #{libexec_dir} and #{etc_dir}" do
  command "sudo install -d -m 0755 -o root -g root #{libexec_dir} && " \
          "sudo install -d -m 0750 -o root -g #{tracker_user} #{etc_dir}"
  not_if "test -d #{libexec_dir} && test -d #{etc_dir}"
end

# --- script ---------------------------------------------------------------------

script_staged = "#{staging_dir}/mac-block-tracker.sh"
remote_file script_staged do
  source "files/mac-block-tracker.sh"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

execute "install mac-block-tracker.sh" do
  command "sudo install -m 0755 -o root -g root #{script_staged} #{libexec_dir}/mac-block-tracker.sh"
  not_if "diff -q #{script_staged} #{libexec_dir}/mac-block-tracker.sh 2>/dev/null"
end

# --- router host key ------------------------------------------------------------

# The tracker connects with StrictHostKeyChecking=yes against this file only,
# so a first connection cannot be steered to an impostor. The key is the RSA
# host key whose fingerprint home-monitor's rtx_sshd_host_key.main records in
# state (SHA256:IG5wh++ETKZvhr6PgG3yYoJM89ks24ppHdTC5D1uhaI, checked
# 2026-10-02). If the router's host key is ever regenerated, the tracker fails
# and mails until this file is updated.
known_hosts_staged = "#{staging_dir}/rtx-hnd.known_hosts"
remote_file known_hosts_staged do
  source "files/rtx-hnd.known_hosts"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
end

execute "install #{etc_dir}/known_hosts" do
  command "sudo install -m 0644 -o root -g root #{known_hosts_staged} #{etc_dir}/known_hosts"
  not_if "diff -q #{known_hosts_staged} #{etc_dir}/known_hosts 2>/dev/null"
end

# --- credential -----------------------------------------------------------------

# Content-aware skip: both keys present. The file is 0640 root:#{tracker_user},
# so an operator-user apply cannot read it; `sudo -n` succeeds for root (the
# auto-mitamae path) and for an operator with a warm sudo timestamp, and a
# failed check only means the generator re-fetches the same values.
env_keys_present = lambda do
  run_command(
    "sudo -n grep -q '^AWS_ACCESS_KEY_ID=.' #{env_path} && " \
    "sudo -n grep -q '^AWS_SECRET_ACCESS_KEY=.' #{env_path}",
    error: false,
  ).exit_status == 0
end

require_external_auth(
  tool_name: "AWS SSM access for /mac-block-tracker/* (profile=#{aws_profile}, region=#{aws_region})",
  check_command: "aws ssm get-parameter --name /mac-block-tracker/secret-access-key --with-decryption " \
                 "--query Parameter.Name --output text --profile #{aws_profile} --region #{aws_region} >/dev/null 2>&1",
  instructions: "The #{aws_profile} profile must be able to read /mac-block-tracker/access-key-id and " \
                "/mac-block-tracker/secret-access-key (created by home-monitor mac-block-tracker.tf). " \
                "Then press Enter to retry.",
  skip_if: env_keys_present,
) do
  # No `user`: mitamae would wrap it in `sudo -H -u`, whose env_reset drops the
  # operator's AWS config resolution. The values never appear on a command line.
  execute "generate #{env_path}" do
    command <<~SH
      set -e
      umask 077
      tmp=$(mktemp)
      trap 'rm -f "$tmp"' EXIT
      AKID=$(aws ssm get-parameter --name /mac-block-tracker/access-key-id --with-decryption --query Parameter.Value --output text --profile #{aws_profile} --region #{aws_region})
      SAK=$(aws ssm get-parameter --name /mac-block-tracker/secret-access-key --with-decryption --query Parameter.Value --output text --profile #{aws_profile} --region #{aws_region})
      test -n "$AKID" && test -n "$SAK"
      printf 'AWS_ACCESS_KEY_ID=%s\\nAWS_SECRET_ACCESS_KEY=%s\\n' "$AKID" "$SAK" >"$tmp"
      sudo install -m 0640 -o root -g #{tracker_user} "$tmp" #{env_path}
    SH
  end
end

# --- systemd --------------------------------------------------------------------

service_staged = "#{staging_dir}/mac-block-tracker.service"
remote_file service_staged do
  source "files/mac-block-tracker.service"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
end

timer_staged = "#{staging_dir}/mac-block-tracker.timer"
remote_file timer_staged do
  source "files/mac-block-tracker.timer"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
end

systemd_unit "mac-block-tracker.service" do
  staging_path service_staged
  start false
end

systemd_unit "mac-block-tracker.timer" do
  staging_path timer_staged
  companion_unit "mac-block-tracker.service"
end
