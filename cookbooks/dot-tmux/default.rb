# frozen_string_literal: true

# Depends on ssh-keys: the private device key (~/.ssh/<host>_ed25519) must be
# in place before `git@github.com:shin1ohno/tmux.git` can be cloned. ssh-keys
# pauses for AWS auth itself, so by the time we reach here the key is on
# disk. The matching public key is registered to github.com/shin1ohno via
# home-monitor's Terraform `github_user_ssh_key.device[*]` (run that first
# on a brand-new machine).
include_cookbook "ssh-keys"

home = node[:setup][:home]

directory "#{home}/.config/tmux/plugins" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

# This step PUSHES to the personal shin1ohno/tmux repo, so it needs actual
# SSH write access, not just a key -- probe real auth to github.com rather
# than just checking a key file exists. Hosts with no SSH key at all (GCE
# OS Login boxes, by design) or a key not yet registered to this GitHub
# account both fail the same way and should skip gracefully instead of
# aborting the whole linux.rb run (mitamae has no ignore_failure).
dot_tmux_ssh_auth_ok = run_command(
  "ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new git@github.com 2>&1",
  error: false,
).stdout.include?("successfully authenticated")

unless dot_tmux_ssh_auth_ok
  MItamae.logger.warn(
    "dot-tmux: no SSH write access to git@github.com -- skipping personal " \
    "tmux dotfiles sync (~/.config/tmux stays local-only). Expected on hosts " \
    "with no SSH private key. Re-run this cookbook once one is set up if you " \
    "want it synced.",
  )
end

execute "Initialise tmux config directory" do
  command <<EOF
    GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' && export GIT_SSH_COMMAND &&\n
    git init &&\n
    git remote add origin git@github.com:shin1ohno/tmux.git &&\n
    git pull --rebase origin main &&\n
    git push --set-upstream origin main
EOF
  cwd "#{home}/.config/tmux"
  not_if { File.exist? "#{home}/.config/tmux/.git" }
  only_if { dot_tmux_ssh_auth_ok }
end

# Symlink ~/.tmux.conf -> ~/.config/tmux/tmux.conf BEFORE TPM's install_plugins
# runs. TPM's check_tpm_configured.sh calls `tmux start-server \; show-environment
# -g TMUX_PLUGIN_MANAGER_PATH` and expects the conf to be loaded so the
# `run "...tpm/tpm"` directive can set that variable. Without the legacy
# symlink, some tmux startup paths skip XDG fallback and TPM aborts with
# "FATAL: Tmux Plugin Manager not configured in tmux.conf".
tmux_conf_legacy = "#{home}/.tmux.conf"
tmux_conf_xdg    = "#{home}/.config/tmux/tmux.conf"

execute "symlink #{tmux_conf_legacy} -> #{tmux_conf_xdg}" do
  command "ln -sf '#{tmux_conf_xdg}' '#{tmux_conf_legacy}'"
  user node[:setup][:user]
  only_if "test -f '#{tmux_conf_xdg}'"
  not_if "test -L '#{tmux_conf_legacy}' && test \"$(readlink '#{tmux_conf_legacy}')\" = '#{tmux_conf_xdg}'"
end

# Split TPM clone from plugin install. The previous shape combined them
# under a single `not_if` on the TPM directory's existence, which silently
# skipped install_plugins on a re-apply when a prior run had cloned TPM
# but aborted before installing the plugins. tmux-sensible is the first
# `@plugin` declared after TPM itself, so its presence is a reliable
# "install_plugins succeeded" marker.
#
# `cwd home` keeps subprocesses (bash → tmux → tpm script) from inheriting
# mitamae's invocation directory (the setup repo root, which carries an
# untrusted mise.toml). Without this, mise's PATH-shim resolution walks
# up from the inherited cwd and emits "mise.toml not trusted" errors on
# every subprocess in the install_plugins chain.
execute "clone TPM" do
  command "git clone https://github.com/tmux-plugins/tpm #{home}/.config/tmux/plugins/tpm"
  cwd home
  not_if { File.exist? "#{home}/.config/tmux/plugins/tpm/.git" }
end

# Requires tmux_conf_xdg to exist: TPM's install_plugins reads tmux.conf for
# `@plugin`/`run "...tpm/tpm"` declarations, and aborts with "FATAL: Tmux
# Plugin Manager not configured in tmux.conf" if the file is missing --
# which it is whenever the personal dotfiles sync above was skipped (no SSH
# write access). Confirmed live: this cascaded into the same
# whole-linux.rb-aborts failure mode as the push step itself.
execute "install TPM plugins" do
  command "#{home}/.config/tmux/plugins/tpm/bin/install_plugins"
  cwd home
  only_if "test -x #{home}/.config/tmux/plugins/tpm/bin/install_plugins && test -f '#{tmux_conf_xdg}'"
  not_if "test -d #{home}/.config/tmux/plugins/tmux-sensible/.git"
end

execute "update tmux config" do
  command "GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' git pull --rebase origin main || true"
  cwd "#{home}/.config/tmux"
  only_if "test -d #{home}/.config/tmux/.git"
end
