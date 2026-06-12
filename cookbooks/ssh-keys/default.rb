# frozen_string_literal: true

# SSH Key Management
#
# Fetches the canonical host registry from AWS SSM Parameter Store
# (/host-registry/devices, managed by home-monitor Terraform), then:
# - Places the current device's private key from /ssh-keys/devices/<key>/private
# - Builds authorized_keys with public keys from all devices
# - Generates SSH config entries for peer devices
#
# Prerequisites:
#   - AWS CLI on disk (awscli cookbook handles this)
#   - AWS profile 'pve-bootstrap-ssm' configured (require_external_auth gates)
#   - SSH keys provisioned in SSM (via home-monitor Terraform)
#   - Hostname matching a device key (or hostname_override) in
#     /host-registry/devices

# Ensure aws CLI is on disk before we try to fetch SSM. awscli cookbook
# is idempotent — no-op on hosts that already have it.
include_cookbook "awscli"

# Bootstrap config: only the AWS profile + region the cookbook uses to
# make its first SSM call. The canonical host registry (devices map)
# lives in SSM at /host-registry/devices, not in this repo, so this
# file contains nothing else.
aws_config_file = File.join(File.dirname(__FILE__), "files", "aws-config.json")
aws_config = JSON.parse(File.read(aws_config_file))
aws_profile = aws_config["aws_profile"]
aws_region = aws_config["aws_region"]

# AWS auth + SSM access required to fetch the host registry. Pause here
# on a fresh machine until both are in place. The check actually attempts
# the SSM read on /host-registry/devices — this verifies (a) the named
# profile exists, (b) credentials are valid, (c) the region is right,
# and (d) the IAM principal has ssm:GetParameter on the path.
host_registry_check = "aws ssm get-parameter --name /host-registry/devices " \
                      "--query Parameter.Value --output text " \
                      "--profile #{aws_profile} --region #{aws_region} > /dev/null 2>&1"
require_external_auth(
  tool_name: "AWS SSM access (profile=#{aws_profile}, region=#{aws_region})",
  tool_binary: "aws",
  check_command: host_registry_check,
  instructions: "Configure the '#{aws_profile}' profile with credentials that have " \
                "ssm:GetParameter on /host-registry/devices and /ssh-keys/devices/* " \
                "in #{aws_region}. On a fresh machine: " \
                "`aws configure --profile #{aws_profile}` (or run bin/bootstrap-lxc-creds " \
                "from the PVE host for LXCs). Then press Enter.",
)

# Helper: fetch a parameter from SSM. Defined here (after auth gate) so
# the gate failure path can short-circuit before any SSM call below.
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

# Fetch the canonical host registry. This is the single source of truth
# for cross-repo device metadata since Phase A round-table 2026-05-07.
# Source: home-monitor/contracts/devices.json (git-managed) → SSM
# (Terraform-managed) → here.
host_registry_json = fetch_ssm.call("/host-registry/devices")
unless host_registry_json
  MItamae.logger.warn(
    "ssh-keys: failed to fetch /host-registry/devices from SSM despite " \
    "passing require_external_auth. This is unexpected — check whether " \
    "home-monitor terraform apply created aws_ssm_parameter.host_registry_devices."
  )
  return
end

config = JSON.parse(host_registry_json)
devices = config["devices"]                 # Hash<key, device>

# Identify current device by hostname-s. Registry entries can override
# matching with an explicit `hostname_override` field when the device's
# OS-level hostname differs from its conceptual key — e.g. a Mac whose
# factory serial-format short hostname (`XMHTM6QVQX`) is unrelated to
# the human label (`air`) used in SSH config / authorized_keys comments.
current_device_name = run_command("hostname -s").stdout.strip.downcase
current_device_key, current_device = devices.find do |k, d|
  (d["hostname_override"] || k).downcase == current_device_name
end

unless current_device
  MItamae.logger.warn(
    "ssh-keys: hostname '#{current_device_name}' not in /host-registry/devices — " \
    "no authorized_keys / private key written. Add this host to " \
    "home-monitor/contracts/devices.json (with hostname_override if needed) " \
    "and apply terraform if ssh-key distribution is intended."
  )
  return
end

# Skip client-only devices (e.g. ios)
if current_device["client_only"]
  MItamae.logger.info("ssh-keys: device '#{current_device_name}' is client-only, skipping")
  return
end

user = node[:setup][:user]
group = node[:setup][:group]
home = node[:setup][:home]
ssh_dir = "#{home}/.ssh"

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
  next unless ssm_prefix # skip entries lacking SSH data

  pub = fetch_ssm.call("#{ssm_prefix}/public")
  next unless pub

  pub_line = pub.strip
  # Append device key as comment if not already present
  parts = pub_line.split(/\s+/)
  pub_line = "#{pub_line} #{k}" if parts.length < 3

  key_id = "#{parts[0]} #{parts[1]}"
  if seen_keys.key?(key_id)
    # Merge the new device's key into the existing line's comment field
    # so both names are recorded (e.g. "ssh-ed25519 AAAA... pro,pro-dev").
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
#
# AddKeysToAgent yes: load the key into ssh-agent on first OpenSSH use.
# Tools that link libgit2/libssh2 (e.g. sheldon) authenticate to github
# ONLY via ssh-agent — they do not read ~/.ssh/config IdentityFile nor any
# default key path. With the global `url."git@github.com:".insteadOf` rewrite
# in ~/.gitconfig, sheldon's https plugin URLs become SSH; if the key isn't
# in the agent the libgit2 clone hangs (no socket, threads in cond_wait) and
# `sheldon source` stalls on every shell startup. Any git op to github warms
# the agent so subsequent `sheldon lock`/plugin updates work.
# Scoped to `user git` (not a bare `Host github.com`) so this personal-key
# stanza does NOT also capture org-cert connections made as
# `org-<id>@github.com` (GitHub SSH certificate authorities — e.g. Mercari's
# kouzoh org, configured out-of-band in ~/.ssh/config.d/00-mercari-github).
# A bare `Host github.com` adds this device IdentityFile for EVERY github.com
# user, and because IdentityFile is additive and explicit IdentityFiles are
# offered before agent-only certificates, the personal key shadows the org
# cert — org clones then fail with a SAML SSO authorization error. Limiting to
# `user git` lets `org-*` fall through to the org agent's certificate while
# personal `git@github.com` still uses the device key.
config_entries << "Match host github.com user git"
config_entries << "    HostName github.com"
config_entries << "    User git"
config_entries << "    IdentityFile #{ssh_dir}/#{current_device['ssh']['key_file']}"
config_entries << "    IdentitiesOnly yes"
config_entries << "    AddKeysToAgent yes"
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

# --- Step 5: Pre-populate ~/.ssh/known_hosts with github.com host keys ---
#
# Without this, `git clone git@github.com:...` on a fresh machine fails
# with "Host key verification failed" because:
#   1. ~/.ssh/known_hosts is empty (no prior connection)
#   2. cookbooks/functions/default.rb's git_clone uses
#      GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5', which
#      disables the interactive "yes/no/fingerprint?" prompt
#
# Downstream clone-doing cookbooks (fzf, fzf-tab, oh-my-zsh via dot-zsh,
# dot-tmux, dot-config-nvim, managed-projects) all rely on this entry
# being present before they run.
#
# Pre-populate via `ssh-keyscan` + fingerprint verification against
# GitHub's canonical published values (api.github.com/meta —
# ssh_key_fingerprints). Mismatch fails the cookbook loudly (likely DNS
# hijack / MITM — never silently install an unverified host key).
github_known_hosts_script = <<~SH
  set -euo pipefail
  KNOWN='#{ssh_dir}/known_hosts'
  TMP=$(mktemp)
  trap 'rm -f "$TMP"' EXIT

  ssh-keyscan -t rsa,ecdsa,ed25519 -T 10 github.com 2>/dev/null > "$TMP"
  if [ ! -s "$TMP" ]; then
    echo "ssh-keys: ssh-keyscan github.com returned no output" >&2
    exit 1
  fi

  expected=$(printf '%s\\n%s\\n%s\\n' \\
    'SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM' \\
    'SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s' \\
    'SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU' \\
    | sort)
  actual=$(ssh-keygen -lf "$TMP" | awk '{print $2}' | sort)

  if [ "$actual" != "$expected" ]; then
    echo "ssh-keys: github.com host key fingerprint mismatch (possible MITM / DNS hijack)" >&2
    echo "expected:" >&2; echo "$expected" >&2
    echo "actual:" >&2;   echo "$actual" >&2
    exit 1
  fi

  touch "$KNOWN"
  chmod 600 "$KNOWN"
  cat "$TMP" >> "$KNOWN"
SH

execute "register github.com host keys in known_hosts" do
  command github_known_hosts_script
  user user
  not_if "test -f #{ssh_dir}/known_hosts && grep -q '^github.com ' #{ssh_dir}/known_hosts"
end
