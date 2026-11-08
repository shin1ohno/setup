# frozen_string_literal: true
#
# session-search (shared half): the `ccs` client package, its launcher, and —
# on personal hosts only — the client config and its two secrets.
# Design: docs/design/claude-session-search.md §6.3 (C3), §6.4 (C5), §6.6 (C7),
# §6.8 (C9), §7.5 (client files). Source of the package: docs/adr/0014.
#
# Included first by darwin.rb and linux.rb, which then add the sweep timer
# (launchd agent / systemd user timer). Locals do not cross an include_recipe
# boundary, so the values the callers need are published on
# node[:session_search].
#
# Layout (for the target user):
#   ~/.local/share/session-search/deploy-pinned.sh
#                                           fetches and verifies the package
#   ~/.local/share/session-search/src/      git repository the pin is fetched into
#   ~/.local/share/session-search/ccs/      the Python package (stdlib only) from
#                                           shin1ohno/session-search at the SHA in
#                                           session-search.pin, including the
#                                           vendored session_redact.py and
#                                           session_codex.py
#   ~/.local/share/session-search/DEPLOYED_{SHA,MANIFEST}
#                                           what was verified and deployed
#   ~/.local/bin/ccs                        launcher
#   ~/.claude/session-search/               state.json, lock, breaker.json (0700)
#   ~/.config/session-search/               config.json, client.secret, hmac.key
#                                           (personal hosts; work hosts get them
#                                           from the private overlay)
#
# Deployment guard: the package ships with its masking library, and everything
# that depends on the package is skipped by a converge-time `only_if` on
# `deploy-pinned.sh check` until a verified deployment of the pin exists. A WARN
# is logged meanwhile — the client must never run without the redactor (fail
# closed, §6.2).
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
bin_dir      = "#{target_home}/.local/bin"
launcher     = "#{bin_dir}/ccs"
state_dir    = "#{target_home}/.claude/session-search"
config_dir   = "#{target_home}/.config/session-search"

session_search_pin = File.read(File.join(File.dirname(__FILE__), "session-search.pin")).strip
raise "session-search.pin must be one 40-hex SHA" unless session_search_pin =~ /\A[0-9a-f]{40}\z/

deploy_script = "#{share_dir}/deploy-pinned.sh"
deploy_check  = "/bin/bash #{deploy_script} check #{session_search_pin} #{share_dir}"
# The script belongs to the target user, so a root apply must not run it as root.
# The id test is at run time so a guard already running as that user does not
# call sudo again, which could ask for a password.
deployment_ok = %(if [ "$(id -u)" = 0 ]; then sudo -H -u #{target_user} -- #{deploy_check}; else #{deploy_check}; fi)

node.reverse_merge!(
  session_search: {
    skip: false,
    user: target_user,
    home: target_home,
    group: target_group,
    launcher: launcher,
    redactor_gate: deployment_ok,
  },
)

# No mode on the shared parents: other cookbooks own their permissions. These
# and share_dir exist before the first deploy, so they cannot wait for one.
["#{target_home}/.local", "#{target_home}/.local/share"].each do |d|
  directory d do
    owner target_user
    group target_group
  end
end

directory share_dir do
  owner target_user
  group target_group
  mode "755"
end

# Installed where the target user can read it: pro-dev's auto-mitamae applies as
# root from a checkout that user cannot read.
remote_file deploy_script do
  source "files/deploy-pinned.sh"
  owner target_user
  group target_group
  mode "755"
end

execute "deploy ccs from the pinned session-search" do
  command "/bin/bash #{deploy_script} deploy #{session_search_pin} #{share_dir}"
  user target_user
  not_if deployment_ok
end

# After the deploy step, so a first deploy that succeeded does not warn.
local_ruby_block "session-search: warn when no verified deployment exists" do
  block do
    MItamae.logger.warn(
      "session-search: no verified deployment of #{session_search_pin} in #{share_dir} — " \
      "the ccs client is not installed or updated (it ships only together with its masking library).",
    )
  end
  not_if deployment_ok
end

["#{target_home}/.config", "#{target_home}/.claude"].each do |d|
  directory d do
    owner target_user
    group target_group
    only_if deployment_ok
  end
end

directory bin_dir do
  owner target_user
  group target_group
  mode "755"
  only_if deployment_ok
end

[state_dir, config_dir].each do |d|
  directory d do
    owner target_user
    group target_group
    mode "700"
    only_if deployment_ok
  end
end

# The interpreter is resolved once, here, to the real binary behind `python3`:
# fzf starts `ccs _backend` on every keystroke, and a pyenv shim costs ~140 ms
# per start against ~20 ms for the binary itself (measured on sh1-cloud). If the
# recorded binary disappears (a pyenv version removed), the launcher falls back
# to whatever `python3` is on PATH. A root apply resolves as the target user,
# with their pyenv and home directory, never root's PATH or version selection.
python_probe =
  if run_command("id -u", error: false).stdout.strip == "0"
    <<~SH
      sudo -H -u #{target_user} -- /bin/sh -c '
        cd "$HOME" || exit 1
        unset PYENV_VERSION PYENV_DIR
        export PYENV_ROOT="$HOME/.pyenv"
        export PATH="$PYENV_ROOT/shims:$PYENV_ROOT/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        python3 -I -c "import sys; print(sys.executable)"
      '
    SH
  else
    %q(python3 -I -c 'import sys; print(sys.executable)')
  end
python_result = run_command(python_probe, error: false)
python_real = python_result.stdout.strip
python_real = "" unless python_result.exit_status == 0 && python_real.start_with?("/")

# -I: isolated mode (no PYTHONPATH, no user site, no cwd on sys.path), so a
# planted module in the directory ccs runs from cannot shadow the package.
file launcher do
  content <<~SH
    #!/bin/sh
    # ccs — Claude Code session search (managed by cookbooks/session-search)
    CCS_LAUNCHER=#{launcher}
    export CCS_LAUNCHER
    PY="#{python_real}"
    [ -n "$PY" ] && [ -x "$PY" ] || PY=$(command -v python3)
    exec "$PY" -I -c 'import sys; sys.path.insert(0, "#{share_dir}"); from ccs.cli import main; sys.exit(main(sys.argv[1:]))' "$@"
  SH
  owner target_user
  group target_group
  mode "755"
  only_if deployment_ok
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
    # With no deployment config_dir is not created, so a decrypted temp file
    # could not be placed and would stay on disk.
    only_if deployment_ok
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
