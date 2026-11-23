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
include_platform_cookbook "awscli"

# Bootstrap config: only the AWS profile + region the cookbook uses to
# make its first SSM call. The canonical host registry (devices map)
# lives in SSM at /host-registry/devices, not in this repo, so this
# file contains nothing else.
aws_config_file = File.join(File.dirname(__FILE__), "files", "aws-config.json")
aws_config = JSON.parse(File.read(aws_config_file))
aws_region = aws_config["aws_region"]

# Bare gate + bare fetch_ssm on every platform — auto-select a profile
# with the required permissions instead of pinning a specific name.
#
# - darwin (TTY): require_external_auth's auto-discovery iterates the
#   operator's configured profiles, sets ENV["AWS_PROFILE"] on the first
#   one that satisfies the check_command. fetch_ssm (also bare) inherits
#   that env. The operator does not need to maintain a specific profile
#   name — any profile with the required SSM/KMS scope works.
# - fleet (non-TTY LXC): auto-discovery is TTY-only, so non-TTY apply
#   relies on AWS_PROFILE preset by `cookbooks/auto-mitamae-target/
#   files/mitamae-runner.sh` (exports AWS_PROFILE=pve-bootstrap-ssm
#   before invoking mitamae). bare check_command and bare fetch_ssm then
#   both inherit that env → deterministic, no per-cookbook --profile pin
#   required.
#
# Pin-match lint invariant (~/ManagedProjects/setup/.claude/rules/ruby.md "Auth-check gate"):
# gate and ops are both bare → bare↔bare consistency, no false gate.
# Listed in bin/lint-cookbooks BARE_OK (same category as mcp/local-mcp).
host_registry_check = "aws ssm get-parameter --name /host-registry/devices " \
                      "--query Parameter.Value --output text " \
                      "--region #{aws_region} > /dev/null 2>&1"
require_external_auth(
  tool_name: "AWS SSM access (auto-discovered profile, region=#{aws_region})",
  tool_binary: "aws",
  check_command: host_registry_check,
  instructions: "Configure any AWS profile with ssm:GetParameter on " \
                "/host-registry/devices + /ssh-keys/devices/* AND kms:Decrypt " \
                "on the SSM EncryptionContext in #{aws_region}. " \
                "Refresh via `aws login` or `aws configure --profile <name>`. " \
                "On TTY (darwin): auto-discovery will pick it up. " \
                "On fleet LXC: re-run bin/bootstrap-lxc-creds from the PVE " \
                "host to seed the pve-bootstrap-ssm profile. Then press Enter.",
)

# Helper: fetch a parameter from SSM. Defined here (after auth gate) so
# the gate failure path can short-circuit before any SSM call below.
# Bare — uses whatever profile is selected via AWS_PROFILE env (set by
# the gate's auto-discovery on TTY, or pre-set by mitamae-runner.sh on
# the fleet).
fetch_ssm = ->(path) {
  result = run_command(
    "aws ssm get-parameter" \
    " --name '#{path}'" \
    " --with-decryption" \
    " --query 'Parameter.Value'" \
    " --output text" \
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

  # sensitive: a new or rotated key would otherwise be printed whole in
  # mitamae's INFO-level file diff (the old key as `-` lines too), which the
  # auto-mitamae runner writes to its log on every fleet host (check 15).
  file key_path do
    owner user
    group group
    mode "0600"
    content private_key_content
    sensitive true
  end
end

# --- Step 2: Build authorized_keys with managed section ---

MANAGED_BEGIN = "# BEGIN ssh-keys-managed"
MANAGED_END = "# END ssh-keys-managed"

# Collect public keys from all devices. Multiple devices may share an
# SSM prefix (e.g. pro and pro-dev are twins) — dedup by [key_type,
# key_data] so authorized_keys never carries two visually-different
# lines that resolve to the same key.
#
# Every SSM public value lands in EVERY host's authorized_keys, so only a
# value that is exactly one real public key line is accepted. The RAW value
# is checked before any normalization (fetch_ssm_raw drops only the newline
# the aws CLI adds); public_key_line returns [line, nil] or [nil, reason]:
#   - one line: an optional single trailing LF or CRLF is the only line
#     break allowed; any other C0 control byte (CR, NUL, ESC, a second line,
#     a leading or trailing blank line), DEL, a C1 control (U+0080-U+009F,
#     e.g. U+0085) or U+2028/U+2029 rejects the value. TAB and space are
#     field separators, as in OpenSSH (sshkey.c sshkey_read: strcspn " \t").
#   - at most PUBLIC_KEY_MAX_BYTES bytes (see below).
#   - first field is an allowed key type, so authorized_keys options
#     (command=, from=, restrict) and the "placeholder — …" text of an
#     unfilled ios-client slot are rejected.
#   - the blob is strict base64 (OpenSSH b64_pton: length a multiple of 4,
#     '=' only as final padding, zero slop bits) and decodes to a complete
#     key of the declared type with nothing left over (sshkey.c
#     sshkey_from_blob_internal + the per-type deserialize_public):
#     ed25519 a 32-byte key; ecdsa its curve name and an uncompressed point
#     of the curve's size; rsa two positive mpints, modulus 1024-16384 bits;
#     sk-* the same plus an application string. EC points are not checked
#     to be on the curve (that needs libcrypto).
# Accepted lines are used exactly as before this check (stripped of
# surrounding blanks), so valid keys keep their bytes. A rejected value is
# skipped with a warning naming the SSM path and the reason — never the
# value, which could be a pasted private key.
# Test: cookbooks/ssh-keys/test/test-public-key-validation.rb.
#
# PUBLIC_KEY_MAX_BYTES: current OpenSSH reads authorized_keys with
# getline(3) and has no line limit (auth2-pubkeyfile.c
# auth_check_authkeys_file); 7.3p1 read lines into a fixed
# SSH_MAX_PUBKEY_BYTES = 16384 buffer (ssh.h, misc.c read_keyfile_line)
# and discarded longer lines. The largest key OpenSSH parses is RSA-16384
# (SSHBUF_MAX_BIGNUM = 2048 bytes, sshbuf.h), about 2.8 KB as a line, so
# 4096 bytes fits every allowed key with a comment and stays far below
# 16384.
PUBLIC_KEY_MAX_BYTES = 4096
PUBLIC_KEY_TYPES = {
  "ssh-ed25519" => :ed25519,
  "sk-ssh-ed25519@openssh.com" => :sk_ed25519,
  "ssh-rsa" => :rsa,
  "ecdsa-sha2-nistp256" => :ecdsa,
  "ecdsa-sha2-nistp384" => :ecdsa,
  "ecdsa-sha2-nistp521" => :ecdsa,
  "sk-ecdsa-sha2-nistp256@openssh.com" => :sk_ecdsa,
}.freeze
# Coordinate size in bytes per curve (uncompressed point = 1 + 2 * size).
PUBLIC_KEY_EC_SIZES = { "nistp256" => 32, "nistp384" => 48, "nistp521" => 66 }.freeze
BASE64_VALUES = {}
"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".bytes.each do |b|
  BASE64_VALUES[b] = BASE64_VALUES.size
end

# Strict base64 → Array of byte values, or nil (OpenSSH b64_pton rules).
decode_base64 = ->(text) {
  bytes = text.bytes
  return nil if bytes.empty? || bytes.length % 4 != 0

  pad = 0
  pad += 1 if bytes[-1] == 61 # "="
  pad += 1 if pad == 1 && bytes[-2] == 61
  out = []
  i = 0
  while i < bytes.length
    v = [0, 0, 0, 0]
    j = 0
    while j < 4
      b = bytes[i + j]
      if b == 61
        return nil if i + 4 < bytes.length || j < 4 - pad # "=" only as final padding
      else
        return nil unless BASE64_VALUES.key?(b)

        v[j] = BASE64_VALUES[b]
      end
      j += 1
    end
    n = (v[0] << 18) | (v[1] << 12) | (v[2] << 6) | v[3]
    last = i + 4 == bytes.length
    out << ((n >> 16) & 255)
    out << ((n >> 8) & 255) unless last && pad == 2
    out << (n & 255) unless last && pad >= 1
    i += 4
  end
  # Bits after the last full byte must be zero (b64_pton rejects them).
  return nil if pad == 1 && (v[2] & 3) != 0
  return nil if pad == 2 && (v[1] & 15) != 0

  out
}

# Reads one SSH wire string at pos: [Array of bytes, next pos] or nil.
read_wire_string = ->(blob, pos) {
  return nil if pos + 4 > blob.length

  len = (blob[pos] << 24) | (blob[pos + 1] << 16) | (blob[pos + 2] << 8) | blob[pos + 3]
  return nil if pos + 4 + len > blob.length

  [blob[pos + 4, len], pos + 4 + len]
}

# Positive mpint (sshbuf_get_bignum2_bytes_direct) → its bit count, or nil.
mpint_bits = ->(bytes) {
  return nil if !bytes.empty? && bytes[0] >= 128 # negative
  return nil if bytes.length > 2049 || (bytes.length == 2049 && bytes[0] != 0)

  i = 0
  i += 1 while i < bytes.length && bytes[i] == 0
  return 0 if i == bytes.length

  top = bytes[i]
  bits = 0
  while top > 0
    bits += 1
    top >>= 1
  end
  ((bytes.length - i - 1) * 8) + bits
}

# Returns nil when blob is a complete public key of key_type, else a reason.
public_key_blob_error = ->(key_type, blob) {
  kind = PUBLIC_KEY_TYPES[key_type]
  name, pos = read_wire_string.call(blob, 0)
  return "blob does not start with a key type string" unless name
  return "blob is a different key type than the line says" unless name == key_type.bytes

  case kind
  when :ed25519, :sk_ed25519
    pk, pos = read_wire_string.call(blob, pos)
    return "ed25519 key is not 32 bytes" unless pk && pk.length == 32
  when :ecdsa, :sk_ecdsa
    curve_name = key_type.sub("sk-", "").sub("@openssh.com", "").sub("ecdsa-sha2-", "")
    curve, pos = read_wire_string.call(blob, pos)
    return "ecdsa curve name does not match the key type" unless curve && curve == curve_name.bytes

    point, pos = read_wire_string.call(blob, pos)
    size = PUBLIC_KEY_EC_SIZES[curve_name]
    return "ecdsa point is not an uncompressed #{curve_name} point" unless point && point.length == 1 + (2 * size) && point[0] == 4
  when :rsa
    e, pos = read_wire_string.call(blob, pos)
    return "rsa exponent is missing or negative" unless e && mpint_bits.call(e)

    n, pos = read_wire_string.call(blob, pos)
    bits = n && mpint_bits.call(n)
    return "rsa modulus is missing, negative or outside 1024-16384 bits" unless bits && bits >= 1024 && bits <= 16384
  end
  if kind == :sk_ed25519 || kind == :sk_ecdsa
    app, pos = read_wire_string.call(blob, pos)
    return "security key application string is missing" unless app && !app.include?(0)
  end
  return "blob has trailing data after the key" unless pos == blob.length

  nil
}

public_key_line = ->(raw) {
  value = if raw.end_with?("\r\n")
            raw[0, raw.length - 2]
          elsif raw.end_with?("\n")
            raw[0, raw.length - 1]
          else
            raw
          end
  return [nil, "value is empty"] if value.empty?
  return [nil, "value is longer than #{PUBLIC_KEY_MAX_BYTES} bytes"] if value.bytesize > PUBLIC_KEY_MAX_BYTES

  bytes = value.bytes
  i = 0
  while i < bytes.length
    b = bytes[i]
    if (b < 32 && b != 9) || b == 127
      return [nil, "value has a control character or more than one line"]
    end
    if b == 0xC2 && i + 1 < bytes.length && bytes[i + 1] >= 0x80 && bytes[i + 1] <= 0x9F
      return [nil, "value has a C1 control character (U+0080-U+009F)"]
    end
    if b == 0xE2 && i + 2 < bytes.length && bytes[i + 1] == 0x80 && (bytes[i + 2] == 0xA8 || bytes[i + 2] == 0xA9)
      return [nil, "value has a Unicode line or paragraph separator"]
    end
    i += 1
  end

  line = value.strip
  fields = line.split(/[ \t]+/, 3)
  return [nil, "first field is not an allowed key type (options, placeholder or other text)"] unless PUBLIC_KEY_TYPES.key?(fields[0])
  return [nil, "no key blob after the key type"] unless fields[1]

  blob = decode_base64.call(fields[1])
  return [nil, "key blob is not strict base64"] unless blob

  error = public_key_blob_error.call(fields[0], blob)
  return [nil, error] if error

  [line, nil]
}

# Like fetch_ssm, but returns the value as stored: the aws CLI's text output
# is the value plus one newline, and only that newline is removed.
fetch_ssm_raw = ->(path) {
  result = run_command(
    "aws ssm get-parameter" \
    " --name '#{path}'" \
    " --with-decryption" \
    " --query 'Parameter.Value'" \
    " --output text" \
    " --region '#{aws_region}'",
    error: false
  )
  if result.exit_status != 0
    MItamae.logger.warn("ssh-keys: failed to fetch #{path}")
    nil
  else
    out = result.stdout
    out.end_with?("\n") ? out[0, out.length - 1] : out
  end
}

managed_keys = []
managed_key_data = [] # [key_type, key_data] pairs for dedup
seen_keys = {} # "<key_type> <key_data>" => index in managed_keys
devices.each do |k, dev|
  ssm_prefix = dev.dig("ssh", "ssm_prefix")
  next unless ssm_prefix # skip entries lacking SSH data

  raw_pub = fetch_ssm_raw.call("#{ssm_prefix}/public")
  next unless raw_pub

  pub_line, reject_reason = public_key_line.call(raw_pub)
  unless pub_line
    MItamae.logger.warn("ssh-keys: #{ssm_prefix}/public is not one public key line " \
                        "(#{reject_reason}); not added to authorized_keys")
    next
  end
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
      # The old content (possibly a value a previous run should not have
      # distributed) would otherwise be printed in mitamae's file diff.
      sensitive true
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
      # The old content (possibly a value a previous run should not have
      # distributed) would otherwise be printed in mitamae's file diff.
      sensitive true
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
# `org-<id>@github.com` (GitHub SSH certificate authorities — e.g. the work org's
# work org, configured out-of-band in ~/.ssh/config.d/00-work-github).
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
