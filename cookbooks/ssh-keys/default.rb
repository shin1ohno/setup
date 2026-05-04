# frozen_string_literal: true

# SSH Key Management
#
# Fetches device SSH keys from AWS SSM Parameter Store and configures:
# - Private key for the current device
# - authorized_keys with public keys from all devices
# - SSH config entries for peer devices
#
# Prerequisites:
#   - AWS CLI configured (require_external_auth gates this below)
#   - SSH keys provisioned in SSM (via home-monitor Terraform)
#   - Hostname matching a device name in devices.json

# Ensure aws CLI is on disk before we try to fetch SSM. awscli cookbook
# is idempotent — no-op on hosts that already have it.
include_cookbook "awscli"

# Load device configuration
config_file = File.join(File.dirname(__FILE__), "files", "devices.json")
config = JSON.parse(File.read(config_file))
devices = config["devices"]
aws_profile = config["aws_profile"]
aws_region = config["aws_region"]

# Identify current device by hostname
current_device_name = run_command("hostname -s").stdout.strip.downcase
current_device = devices.find { |d| d["name"] == current_device_name }

unless current_device
  MItamae.logger.info("ssh-keys: hostname '#{current_device_name}' not in devices.json, skipping")
  return
end

# Skip client-only devices (e.g. ios)
if current_device["client_only"]
  MItamae.logger.info("ssh-keys: device '#{current_device_name}' is client-only, skipping")
  return
end

# AWS auth + SSM access required to fetch keys. Pause here on a fresh
# machine until both are in place. The check actually attempts the SSM
# read on the current device's own private key — this verifies (a) the
# named profile exists, (b) credentials are valid, (c) the region is
# right, and (d) the IAM principal has ssm:GetParameter on the path.
# `aws sts get-caller-identity` alone catches only (a) and (b).
device_ssm_check = "aws ssm get-parameter --name #{current_device['ssm_prefix']}/private " \
                   "--with-decryption --query Parameter.Value --output text " \
                   "--profile #{aws_profile} --region #{aws_region} > /dev/null 2>&1"
require_external_auth(
  tool_name: "AWS SSM access (profile=#{aws_profile}, region=#{aws_region})",
  check_command: device_ssm_check,
  instructions: "Configure the '#{aws_profile}' profile with credentials that have " \
                "ssm:GetParameter on /ssh-keys/devices/* in #{aws_region}. " \
                "On a fresh machine: `aws configure --profile #{aws_profile}` and ensure " \
                "the IAM user/role has the required SSM permissions. Then press Enter.",
)

user = node[:setup][:user]
group = node[:setup][:group]
home = node[:setup][:home]
ssh_dir = "#{home}/.ssh"

# Helper: fetch a parameter from SSM
fetch_ssm = ->(path) {
  result = run_command(
    "aws ssm get-parameter" \
    " --name '#{path}'" \
    " --with-decryption" \
    " --query 'Parameter.Value'" \
    " --output text" \
    " --profile '#{aws_profile}'" \
    " --region '#{aws_region}'",
    error: false
  )
  if result.exit_status != 0
    MItamae.logger.warn("ssh-keys: failed to fetch #{path}")
    nil
  else
    result.stdout.strip
  end
}

# Ensure ~/.ssh exists
directory ssh_dir do
  owner user
  group group
  mode "0700"
end

# --- Step 1: Fetch and place own private key ---

private_key = fetch_ssm.call("#{current_device["ssm_prefix"]}/private")
if private_key
  key_path = "#{ssh_dir}/#{current_device["key_file"]}"
  private_key_content = private_key.end_with?("\n") ? private_key : "#{private_key}\n"

  file key_path do
    owner user
    group group
    mode "0600"
    content private_key_content
  end
end

# --- Step 2: Build authorized_keys with managed section ---

MANAGED_BEGIN = "# BEGIN ssh-keys-managed"
MANAGED_END = "# END ssh-keys-managed"

# Collect public keys from all devices. Multiple devices may share an
# SSM prefix (e.g. pro and pro-dev are twins) — dedup by [key_type,
# key_data] so authorized_keys never carries two visually-different
# lines that resolve to the same key.
managed_keys = []
managed_key_data = [] # [key_type, key_data] pairs for dedup
seen_keys = {} # "<key_type> <key_data>" => index in managed_keys
devices.each do |dev|
  pub = fetch_ssm.call("#{dev["ssm_prefix"]}/public")
  next unless pub

  pub_line = pub.strip
  # Append device name as comment if not already present
  parts = pub_line.split(/\s+/)
  pub_line = "#{pub_line} #{dev["name"]}" if parts.length < 3

  key_id = "#{parts[0]} #{parts[1]}"
  if seen_keys.key?(key_id)
    # Merge the new device's name into the existing line's comment
    # field so both names are recorded (e.g. "ssh-ed25519 AAAA... pro,pro-dev").
    idx = seen_keys[key_id]
    existing = managed_keys[idx].split(/\s+/, 3)
    existing_comment = existing[2] || ""
    new_comment = (existing_comment.split(",") + [dev["name"]]).uniq.join(",")
    managed_keys[idx] = "#{existing[0]} #{existing[1]} #{new_comment}"
    next
  end

  seen_keys[key_id] = managed_keys.length
  managed_keys << pub_line
  managed_key_data << parts[0..1] # [key_type, base64_data]
end

if managed_keys.any?
  authorized_keys_path = "#{ssh_dir}/authorized_keys"
  existing_content = File.exist?(authorized_keys_path) ? File.read(authorized_keys_path) : ""
  lines = existing_content.lines.map(&:chomp)

  # Split into unmanaged and managed sections
  unmanaged_lines = []
  in_managed = false
  lines.each do |line|
    if line == MANAGED_BEGIN
      in_managed = true
      next
    elsif line == MANAGED_END
      in_managed = false
      next
    end
    unmanaged_lines << line unless in_managed
  end

  # Deduplicate: remove unmanaged lines whose key-type+key-data match a managed key
  unmanaged_lines = unmanaged_lines.reject do |line|
    next false if line.start_with?("#") || line.strip.empty?

    parts = line.split(/\s+/)
    next false if parts.length < 2

    managed_key_data.any? { |mkd| mkd[0] == parts[0] && mkd[1] == parts[1] }
  end

  # Build final content
  new_lines = unmanaged_lines.dup
  new_lines << "" if new_lines.last && !new_lines.last.empty?
  new_lines << MANAGED_BEGIN
  new_lines.concat(managed_keys)
  new_lines << MANAGED_END
  new_content = new_lines.join("\n") + "\n"

  file authorized_keys_path do
    owner user
    group group
    mode "0600"
    content new_content
  end
end

# --- Step 3: Generate SSH config for peer devices ---

directory "#{ssh_dir}/config.d" do
  owner user
  group group
  mode "0700"
end

config_entries = []
devices.each do |dev|
  next if dev["name"] == current_device_name
  next if dev["client_only"]

  # Match `<device>.<anything>` — covers FQDN / mDNS / Tailscale MagicDNS
  # forms (neo.local, neo.tailnet.ts.net, etc.) without requiring a
  # HostName redirect.
  config_entries << "Host #{dev["name"]}.*"
  config_entries << "    User #{dev["ssh_user"]}"
  config_entries << "    IdentityFile #{ssh_dir}/#{current_device["key_file"]}"
  config_entries << "    IdentitiesOnly yes"
  config_entries << ""
end

# github.com stanza — re-uses the device private key. The matching public
# key is registered to github.com/shin1ohno via home-monitor's
# `github_user_ssh_key.device[*]` Terraform resource. Without this stanza,
# `ssh git@github.com` falls through to the default identity files
# (~/.ssh/id_ed25519 etc.) which don't exist on a fresh machine.
config_entries << "Host github.com"
config_entries << "    HostName github.com"
config_entries << "    User git"
config_entries << "    IdentityFile #{ssh_dir}/#{current_device["key_file"]}"
config_entries << "    IdentitiesOnly yes"
config_entries << ""

file "#{ssh_dir}/config.d/ssh-keys" do
  owner user
  group group
  mode "0600"
  content config_entries.join("\n") + "\n"
end

# --- Step 4: Ensure main SSH config includes config.d ---

config_path = "#{ssh_dir}/config"
include_directive = "Include #{ssh_dir}/config.d/*"

existing_config = File.exist?(config_path) ? File.read(config_path) : ""
unless existing_config.include?(include_directive)
  new_config = "#{include_directive}\n\n#{existing_config}"

  file config_path do
    owner user
    group group
    mode "0644"
    content new_config
  end
end
