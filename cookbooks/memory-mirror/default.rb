# frozen_string_literal: true
#
# memory-mirror — credentials + config for the file-memory mirror hook
# (cookbooks/claude-code/files/hooks/mirror-file-memory.rb) on personal hosts,
# so notes written under ~/.claude/projects/*/memory/ reach the personal
# es-memory store (dataset file-memory) behind mcp.ohno.be.
#
# The hook authenticates as the Hydra client_credentials client
# `memory-mirror` (registered once by bin/register-memory-mirror; the server
# policy limits it to ingest/forget in file-memory). This cookbook places:
#   ~/.config/memory-mirror/client.env  (0600) MEMORY_MIRROR_CLIENT_ID/SECRET,
#                                       from SSM /memory/mirror-client-{id,secret}
#   ~/.claude/memory-mirror.json        (0644) the client_credentials config
# The secret lives outside ~/.claude so the agent never reads it
# (settings.json also denies Read on ~/.config/memory-mirror/**).
#
# Hosts: pro-dev, mini, and neo (FLEET label). air and sh1-cloud are excluded
# on purpose; every other host (work Macs, CI runners) is skipped. The doc_key
# prefix is written into the config (`host`) because a Mac's gethostname is
# not stable.
#
# Target user: a non-root apply (Macs, a manual apply on pro-dev) uses
# node[:setup]. pro-dev's auto-mitamae applies as root, where node[:setup]
# resolves to /root, so the workstation user's home and group are looked up
# instead (Linux-only path; getent is not used so the lookup stays portable).
#
# AWS: the gate is bare (no --profile), like ssh-keys — a Mac apply is
# interactive and require_external_auth auto-discovers a profile that can read
# the parameter; the auto-mitamae runner exports AWS_PROFILE=pve-bootstrap-ssm,
# which is granted /memory/*. Listed in bin/lint-cookbooks BARE_OK. Both paths
# hand the profile over through the process environment, so the generator must
# run without an `execute ... user` (see the gate below).

excluded_labels = %w[air sh1-cloud]
mirror_hostnames = %w[mini pro-dev]
mirror_user = "shin1ohno"

label = node[:profile][:label]
hostname = node[:profile][:hostname]

if excluded_labels.include?(label)
  MItamae.logger.warn(
    "memory-mirror: host '#{hostname}' (label=#{label}) is excluded from the file-memory mirror — skipping.",
  )
  return
end

mirror_host =
  if label == "neo"
    label
  elsif mirror_hostnames.include?(hostname)
    hostname
  end

unless mirror_host
  MItamae.logger.warn(
    "memory-mirror: host '#{hostname}' (label=#{label.inspect}) is not a personal mirror host " \
    "(neo, #{mirror_hostnames.join(', ')}) — skipping.",
  )
  return
end

if run_command("id -u", error: false).stdout.strip == "0"
  target_user = mirror_user
  target_home = run_command("sh -c 'printf %s ~#{mirror_user}'", error: false).stdout.strip
  target_group = run_command("id -gn #{mirror_user}", error: false).stdout.strip
  if target_home.empty? || target_home.start_with?("~") || target_group.empty?
    MItamae.logger.warn(
      "memory-mirror: running as root but user #{mirror_user} could not be resolved " \
      "(home=#{target_home.inspect} group=#{target_group.inspect}) — skipping.",
    )
    return
  end
else
  target_user = node[:setup][:user]
  target_home = node[:setup][:home]
  target_group = node[:setup][:group]
end

ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_region = ssh_keys_config["aws_region"]

config_dir      = "#{target_home}/.config/memory-mirror"
client_env_path = "#{config_dir}/client.env"
config_path     = "#{target_home}/.claude/memory-mirror.json"
env_temp_path   = "#{node[:setup][:root]}/memory-mirror-client.env"

# Defensive: the generator's temp file lives here (per ruby.md).
directory node[:setup][:root] do
  mode "755"
end

# No mode on the two parents: they exist on any host that has run the
# claude-code cookbook / any XDG tool, and their permissions are not ours.
# owner/group matter on a root apply, where mkdir would otherwise leave them
# root-owned inside the user's home.
directory "#{target_home}/.config" do
  owner target_user
  group target_group
end

directory "#{target_home}/.claude" do
  owner target_user
  group target_group
end

directory config_dir do
  owner target_user
  group target_group
  mode "700"
end

# The secret is written by the generator under umask 077 and moved into place
# with an explicit owner; it never appears in argv (printf is a shell builtin)
# or in mitamae's output.
#
# The gate decrypts the SecureString, so it passes only when this identity can
# actually read it, but it queries Parameter.Name: on the TTY path
# require_external_auth strips the `>/dev/null` and re-runs the command with
# its output captured, and mitamae logs captured stdout at debug level (so
# does the "Verify (paste to debug)" line when pasted). The server-side
# decrypt still needs kms:Decrypt; only the printed field differs.
#
# Explicit resources rather than deploy_with_ssm_env: that helper always runs
# its generator as `execute ... user`, which mitamae turns into
# `sudo -H -u <user>`, and sudo's env_reset drops AWS_PROFILE — the only thing
# this bare gate's profile travels in. On pro-dev, root's ~/.aws holds just the
# named pve-bootstrap-ssm profile, so the generator would fail with "Unable to
# locate credentials" and abort the canary apply; on a Mac an auto-discovered
# non-default profile would be lost the same way. With no `user`, the generator
# runs as mitamae itself (root on pro-dev, the operator on a Mac) and inherits
# its environment. skip_if is the same content-aware check the helper builds
# from expected_keys.
env_keys = %w[MEMORY_MIRROR_CLIENT_ID= MEMORY_MIRROR_CLIENT_SECRET=]

require_external_auth(
  tool_name: "AWS SSM access for /memory/mirror-client-* (auto-discovered profile, region=#{aws_region})",
  check_command: "aws ssm get-parameter --name /memory/mirror-client-secret --with-decryption " \
                 "--query Parameter.Name --output text --region #{aws_region} >/dev/null 2>&1",
  instructions: "Configure an AWS profile with ssm:GetParameter on /memory/mirror-client-id and " \
                "/memory/mirror-client-secret plus kms:Decrypt for the SecureString in #{aws_region} " \
                "(pve-bootstrap-ssm and sh1admn both qualify). The parameters are created by " \
                "bin/register-memory-mirror. Then press Enter to retry.",
  skip_if: -> { file_has_all?(client_env_path, env_keys) },
) do
  execute "generate memory-mirror client.env" do
    command <<~SH
      set -e
      umask 077
      CLIENT_ID=$(aws ssm get-parameter --name /memory/mirror-client-id --query Parameter.Value --output text --region #{aws_region})
      CLIENT_SECRET=$(aws ssm get-parameter --name /memory/mirror-client-secret --with-decryption --query Parameter.Value --output text --region #{aws_region})
      test -n "$CLIENT_ID"
      test -n "$CLIENT_SECRET"
      printf 'MEMORY_MIRROR_CLIENT_ID=%s\\nMEMORY_MIRROR_CLIENT_SECRET=%s\\n' "$CLIENT_ID" "$CLIENT_SECRET" > #{env_temp_path}
    SH
  end
end

remote_file client_env_path do
  source env_temp_path
  owner target_user
  group target_group
  mode "600"
  only_if "test -f #{env_temp_path}"
end

file env_temp_path do
  action :delete
  only_if "test -f #{env_temp_path}"
end

mirror_config = {
  "enabled" => true,
  "dataset" => "file-memory",
  "host" => mirror_host,
  "url" => "https://mcp.ohno.be/memory/mcp",
  "auth" => {
    "type" => "client_credentials",
    "token_url" => "https://mcp.ohno.be/oauth2/token",
    "audience" => "memory",
    "credentials_file" => "~/.config/memory-mirror/client.env",
  },
}

# Both guards run at converge: the credentials file may be placed by the
# resource above in this same run, and a config that names a `server` belongs
# to the work overlay (memory-work), which this cookbook must never replace.
file config_path do
  content JSON.pretty_generate(mirror_config) + "\n"
  owner target_user
  group target_group
  mode "644"
  only_if "test -f #{client_env_path}"
  not_if "grep -Eq '\"server\"[[:space:]]*:' #{config_path}"
end
