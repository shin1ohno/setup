# frozen_string_literal: true
#
# session-search (shared half): the `ccs` client package, its launcher, and —
# on personal hosts only — the client config and its two secrets.
# Design: docs/design/claude-session-search.md §6.3 (C3), §6.4 (C5), §6.6 (C7),
# §6.8 (C9), §7.5 (client files).
#
# Included first by darwin.rb and linux.rb, which then add the sweep timer
# (launchd agent / systemd user timer). Locals do not cross an include_recipe
# boundary, so the values the callers need are published on
# node[:session_search].
#
# Layout (for the target user):
#   ~/.local/share/session-search/ccs/      the Python package (stdlib only)
#   ~/.local/share/session-search/ccs/session_redact.py
#                                           the shared redactor, copied at
#                                           converge from the server tree (single
#                                           source, §6.2) — never committed here
#   ~/.local/bin/ccs                        launcher
#   ~/.claude/session-search/               state.json, lock, breaker.json (0700)
#   ~/.config/session-search/               config.json, client.secret, hmac.key
#                                           (personal hosts; work hosts get them
#                                           from the private overlay)
#
# Redactor guard: session_redact.py is owned by the server stream
# (cookbooks/lxc-es-memory/files/memory-mcp/). Until it exists in this
# checkout, every resource below is skipped by a converge-time
# `only_if "test -f <redactor>"` and a WARN is logged — the client must never
# be installed without its masking library (fail closed, §6.2).
#
# Target user: a non-root apply (Macs, a manual apply) uses node[:setup].
# pro-dev's auto-mitamae applies as root, where node[:setup] is /root, so the
# workstation user is resolved instead — the same rule as memory-mirror. On a
# root apply where that user does not exist, nothing is installed.
#
# Personal config: rendered only on the personal hosts, resolved the way
# memory-mirror resolves them (host-profile label `neo`, or the hostnames
# `mini` / `pro-dev`, which have no FLEET label). air and sh1-cloud are work
# hosts: their config comes from the zp-SHIN overlay, so nothing is rendered
# there. Secrets come from SSM through a bare require_external_auth gate (same
# profile handling as memory-mirror; listed in bin/lint-cookbooks BARE_OK):
#   /memory/session-search-client-secret-<host>   Hydra client secret
#   /memory/session-redact-hmac-key               boundary HMAC key
# Until those parameters exist the gate skips with a WARN; it never fails.

workstation_user = "shin1ohno"
personal_hostnames = %w[mini pro-dev]
work_labels = %w[air sh1-cloud]

label = node[:profile][:label]
hostname = node[:profile][:hostname]

if run_command("id -u", error: false).stdout.strip == "0"
  target_user = workstation_user
  target_home = run_command("sh -c 'printf %s ~#{workstation_user}'", error: false).stdout.strip
  target_group = run_command("id -gn #{workstation_user}", error: false).stdout.strip
  if target_home.empty? || target_home.start_with?("~") || target_group.empty?
    MItamae.logger.warn(
      "session-search: running as root but user #{workstation_user} could not be resolved " \
      "(home=#{target_home.inspect} group=#{target_group.inspect}) — skipping the ccs client.",
    )
    node.reverse_merge!(session_search: { skip: true })
    return
  end
else
  target_user = node[:setup][:user]
  target_home = node[:setup][:home]
  target_group = node[:setup][:group]
end

share_dir    = "#{target_home}/.local/share/session-search"
pkg_dir      = "#{share_dir}/ccs"
bin_dir      = "#{target_home}/.local/bin"
launcher     = "#{bin_dir}/ccs"
state_dir    = "#{target_home}/.claude/session-search"
config_dir   = "#{target_home}/.config/session-search"
redactor_src = File.expand_path(File.join(File.dirname(__FILE__), "..", "lxc-es-memory", "files", "memory-mcp", "session_redact.py"))
redactor_ok  = "test -f #{redactor_src}"

node.reverse_merge!(
  session_search: {
    skip: false,
    user: target_user,
    home: target_home,
    group: target_group,
    launcher: launcher,
    redactor_gate: redactor_ok,
  },
)

local_ruby_block "session-search: warn when the shared redactor is absent" do
  block do
    MItamae.logger.warn(
      "session-search: #{redactor_src} not found — the ccs client is not installed " \
      "(it ships only together with its masking library).",
    )
  end
  not_if redactor_ok
end

# No mode on the shared parents: other cookbooks own their permissions.
["#{target_home}/.local", "#{target_home}/.local/share", "#{target_home}/.config", "#{target_home}/.claude"].each do |d|
  directory d do
    owner target_user
    group target_group
    only_if redactor_ok
  end
end

directory bin_dir do
  owner target_user
  group target_group
  mode "755"
  only_if redactor_ok
end

[share_dir, pkg_dir].each do |d|
  directory d do
    owner target_user
    group target_group
    mode "755"
    only_if redactor_ok
  end
end

[state_dir, config_dir].each do |d|
  directory d do
    owner target_user
    group target_group
    mode "700"
    only_if redactor_ok
  end
end

# Explicit list (mruby has no Dir.glob guarantee); tests/ is not installed.
%w[__init__.py __main__.py api.py cli.py config.py extract.py fallback.py ingest.py picker.py resume.py util.py].each do |f|
  remote_file "#{pkg_dir}/#{f}" do
    source "files/ccs/ccs/#{f}"
    owner target_user
    group target_group
    mode "644"
    only_if redactor_ok
  end
end

# No secret inside, but `sensitive` keeps the redactor's pattern table out of
# the runner log diff (and satisfies lint check 15, which cannot tell a
# checked-in absolute source from a converge-time generator output).
remote_file "#{pkg_dir}/session_redact.py" do
  source redactor_src
  owner target_user
  group target_group
  mode "644"
  sensitive true
  only_if redactor_ok
end

# -I: isolated mode (no PYTHONPATH, no user site, no cwd on sys.path), so a
# planted module in the directory ccs runs from cannot shadow the package.
file launcher do
  content <<~SH
    #!/bin/sh
    # ccs — Claude Code session search (managed by cookbooks/session-search)
    CCS_LAUNCHER=#{launcher}
    export CCS_LAUNCHER
    exec /usr/bin/env python3 -I -c 'import sys; sys.path.insert(0, "#{share_dir}"); from ccs.cli import main; sys.exit(main(sys.argv[1:]))' "$@"
  SH
  owner target_user
  group target_group
  mode "755"
  only_if redactor_ok
end

# --- personal config (pro-dev, mini, neo) -----------------------------------

personal_host =
  if work_labels.include?(label)
    nil
  elsif label == "neo"
    label
  elsif personal_hostnames.include?(hostname)
    hostname
  end

unless personal_host
  MItamae.logger.info(
    "session-search: host '#{hostname}' (label=#{label.inspect}) is not a personal host — " \
    "config.json is not rendered here (work hosts get it from the private overlay).",
  )
  return
end

# The redactor file is checked in (not produced by a resource), so reading its
# presence at compile time is safe; it only decides whether to run the SSM gate
# at all — no point prompting for secrets of a client that will not install.
unless run_command(redactor_ok, error: false).exit_status == 0
  return
end

ssh_keys_config = JSON.parse(File.read(File.join(File.dirname(__FILE__), "..", "ssh-keys", "files", "aws-config.json")))
aws_region = ssh_keys_config["aws_region"]

secret_param  = "/memory/session-search-client-secret-#{personal_host}"
hmac_param    = "/memory/session-redact-hmac-key"
secret_path   = "#{config_dir}/client.secret"
hmac_path     = "#{config_dir}/hmac.key"
config_path   = "#{config_dir}/config.json"
secret_tmp    = "#{node[:setup][:root]}/session-search-client.secret"
hmac_tmp      = "#{node[:setup][:root]}/session-search-hmac.key"

directory node[:setup][:root] do
  mode "755"
end

# Same shape as memory-mirror: the gate decrypts but prints only the name
# (require_external_auth re-runs it with output captured on the TTY path); the
# generator runs without `user`, so the auto-discovered AWS_PROFILE (Mac) or
# the runner's AWS_PROFILE=pve-bootstrap-ssm (pro-dev) survives — `execute
# ... user` would go through sudo's env_reset. Values are written by printf (a
# builtin, never argv) under umask 077, with no trailing newline.
require_external_auth(
  tool_name: "AWS SSM access for #{secret_param} (auto-discovered profile, region=#{aws_region})",
  check_command: "aws ssm get-parameter --name #{secret_param} --with-decryption " \
                 "--query Parameter.Name --output text --region #{aws_region} >/dev/null 2>&1",
  instructions: "Configure an AWS profile with ssm:GetParameter + kms:Decrypt on #{secret_param} and " \
                "#{hmac_param} in #{aws_region} (pve-bootstrap-ssm qualifies). The parameters are created " \
                "with the personal session-search rollout; until then this step is skipped. Press Enter to retry.",
  skip_if: -> { run_command("test -s #{secret_path} && test -s #{hmac_path}", error: false).exit_status == 0 },
) do
  execute "generate session-search client secret and hmac key" do
    command <<~SH
      set -e
      umask 077
      SECRET=$(aws ssm get-parameter --name #{secret_param} --with-decryption --query Parameter.Value --output text --region #{aws_region})
      HKEY=$(aws ssm get-parameter --name #{hmac_param} --with-decryption --query Parameter.Value --output text --region #{aws_region})
      test -n "$SECRET"
      test -n "$HKEY"
      printf '%s' "$SECRET" > #{secret_tmp}
      printf '%s' "$HKEY" > #{hmac_tmp}
    SH
  end
end

[[secret_tmp, secret_path], [hmac_tmp, hmac_path]].each do |tmp, dest|
  remote_file dest do
    source tmp
    owner target_user
    group target_group
    mode "600"
    sensitive true
    only_if "test -f #{tmp}"
  end

  file tmp do
    action :delete
    only_if "test -f #{tmp}"
  end
end

client_config = {
  "endpoint" => "https://mcp.ohno.be/memory/sessions/v1",
  "host_label" => personal_host,
  "auth" => {
    "type" => "client_credentials",
    "token_url" => "https://mcp.ohno.be/oauth2/token",
    "client_id" => "session-search-#{personal_host}",
    "secret_file" => "~/.config/session-search/client.secret",
  },
  "hmac_key_file" => "~/.config/session-search/hmac.key",
}

# Rendered only once both secrets are in place, so a half-configured host
# reads as "not configured" rather than failing on every sweep.
file config_path do
  content JSON.pretty_generate(client_config) + "\n"
  owner target_user
  group target_group
  mode "600"
  only_if "test -s #{secret_path} && test -s #{hmac_path}"
end
