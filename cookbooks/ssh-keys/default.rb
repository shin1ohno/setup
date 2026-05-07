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
#   - Hostname matching a device key (or hostname_override) in
#     contracts/devices.json (loaded via cookbooks/ssh-keys/files/devices.json
#     symlink to the home-monitor submodule)

# Ensure aws CLI is on disk before we try to fetch SSM. awscli cookbook
# is idempotent — no-op on hosts that already have it.
include_cookbook "awscli"

# Load device configuration. devices.json is a symlink into the
# home-monitor submodule (external/home-monitor/contracts/devices.json,
# canonical since Phase A round-table 2026-05-07). New nested schema:
#   devices: { "<key>": { kind, ssh: {user,key_name,key_file,ssm_prefix,ssh_host},
#                         hostname_override?, client_only?, lxc?: {...} } }
config_file = File.join(File.dirname(__FILE__), "files", "devices.json")
config = JSON.parse(File.read(config_file))
devices = config["devices"]
aws_profile = config["aws_profile"]
aws_region = config["aws_region"]

# Identify current device by hostname-s. devices.json entries can override
# matching with an explicit `hostname_override` field when the device's
# OS-level hostname differs from its conceptual key — e.g. a Mac whose
# factory serial-format short hostname (`XMHTM6QVQX`) is unrelated to the
# human label (`air`) used in SSH config / authorized_keys comments.
current_device_name = run_command("hostname -s").stdout.strip.downcase
current_device_key, current_device = devices.find do |k, d|
  (d["hostname_override"] || k).downcase == current_device_name
end

unless current_device
  MItamae.logger.warn(
    "ssh-keys: hostname '#{current_device_name}' not in contracts/devices.json — " \
    "no authorized_keys / private key written. Add this host to " \
    "external/home-monitor/contracts/devices.json (with hostname_override " \
    "if needed) if ssh-key distribution is intended."
  )
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
device_ssm_check = "aws ssm get-parameter --name #{current_device['ssh']['ssm_prefix']}/private " \
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

private_key = fetch_ssm.call("#{current_device['ssh']['ssm_prefix']}/private")
if private_key
  key_path = "#{ssh_dir}/#{current_device['ssh']['key_file']}"
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
devices.each do |k, dev|
  ssm_prefix = dev.dig("ssh", "ssm_prefix")
  next unless ssm_prefix # client_only ios entries lack ssm_prefix in some shapes; skip safely

  pub = fetch_ssm.call("#{ssm_prefix}/public")
  next unless pub

  pub_line = pub.strip
  # Append device key as comment if not already present
  parts = pub_line.split(/\s+/)
  pub_line = "#{pub_line} #{k}" if parts.length < 3

  key_id = "#{parts[0]} #{parts[1]}"
  if seen_keys.key?(key_id)
    # Merge the new device's key into the existing line's comment
    # field so both names are recorded (e.g. "ssh-ed25519 AAAA... pro,pro-dev").
    idx = seen_keys[key_id]
    existing = managed_keys[idx].split(/\s+/, 3)
    existing_comment = existing[2] || ""
    new_comment = (existing_comment.split(",") + [k]).uniq.join(",")
    managed_keys[idx] = "#{existing[0]} #{existing[1]} #{new_comment}"
    next
  end

  seen_keys[key_id] = managed_keys.length
  managed_keys << pub_line
  managed_key_data << parts[0..1] # [key_type, base64_data]
end

if managed_keys.any?
  authorized_keys_path = "#{ssh_dir}/authorized_keys"

  # PVE host: /root/.ssh/authorized_keys is a symlink to
  # /etc/pve/priv/authorized_keys (pmxcfs FUSE mount). pmxcfs disallows chown,
  # so mitamae's file resource (which uses `cp -p` to preserve ownership) fails
  # with "Operation not permitted". Detect the symlink, resolve it, and write
  # via shell redirection so ownership stays as pmxcfs-enforced
  # (root:www-data 0640) — the same path PVE Web UI / cluster setup uses.
  is_pmxcfs_target = File.symlink?(authorized_keys_path) &&
                     File.realpath(authorized_keys_path).start_with?("/etc/pve/")
  resolved_path = is_pmxcfs_target ? File.realpath(authorized_keys_path) : authorized_keys_path

  existing_content = File.exist?(resolved_path) ? File.read(resolved_path) : ""
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

  if is_pmxcfs_target
    # Stage in user space, then `cat > target` rewrites pmxcfs file content
    # without touching ownership. mitamae's file resource would chown via
    # `cp -p` and fail.
    staging_dir = "#{node[:setup][:root]}/ssh-keys"
    staging_path = "#{staging_dir}/authorized_keys.staged"

    directory staging_dir do
      owner user
      group group
      mode "0700"
    end

    file staging_path do
      owner user
      group group
      mode "0600"
      content new_content
    end

    execute "deploy authorized_keys to pmxcfs (#{resolved_path})" do
      command "cat '#{staging_path}' > '#{resolved_path}'"
      not_if "diff -q '#{staging_path}' '#{resolved_path}' >/dev/null 2>&1"
    end
  else
    file authorized_keys_path do
      owner user
      group group
      mode "0600"
      content new_content
    end
  end
end

# --- Step 3: Generate SSH config for peer devices ---

directory "#{ssh_dir}/config.d" do
  owner user
  group group
  mode "0700"
end

config_entries = []
devices.each do |k, dev|
  next if k == current_device_key
  next if dev["client_only"]
  next unless dev["ssh"] && dev["ssh"]["user"]  # need a login user to render Host stanza

  # Match `<device>.<anything>` — covers FQDN / mDNS / Tailscale MagicDNS
  # forms (neo.local, neo.tailnet.ts.net, etc.) without requiring a
  # HostName redirect.
  config_entries << "Host #{k}.*"
  config_entries << "    User #{dev['ssh']['user']}"
  config_entries << "    IdentityFile #{ssh_dir}/#{current_device['ssh']['key_file']}"
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
config_entries << "    IdentityFile #{ssh_dir}/#{current_device['ssh']['key_file']}"
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
