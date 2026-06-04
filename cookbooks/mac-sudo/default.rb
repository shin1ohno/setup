# frozen_string_literal: true
#
# mac-sudo: cut sudo auth friction during interactive mitamae runs on macOS.
#
# Problem: macOS sudo (1.9.x) defaults to tty_tickets — the credential cache is
# keyed per controlling tty. mitamae runs every `execute "sudo ..."` resource in
# its own specinfra subshell (a different / absent tty), so each one re-prompts
# even seconds after the last. A full `darwin.rb` apply asks for the password
# dozens of times.
#
# Two independent, low-blast-radius changes:
#
#   1. /etc/sudoers.d/setup-sudo-timestamp — `Defaults:<user> timestamp_type=global`.
#      A global timestamp shares the credential cache across all of the user's
#      processes (not per-tty), so one successful auth covers the whole apply.
#      Scoped to the apply user to keep the change off every other principal.
#      Installed only after `visudo -cf` validates the staged file — a malformed
#      sudoers drop-in would break ALL sudo, so the syntax gate is mandatory.
#
#   2. /etc/pam.d/sudo_local — enable Touch ID (pam_tid). /etc/pam.d/sudo already
#      `include`s sudo_local; Apple ships only sudo_local.template. With #1 the
#      prompt is rare, and Touch ID turns that one prompt into a fingerprint tap.
#      sudo_local survives macOS updates (unlike edits to /etc/pam.d/sudo).
#
# The org-managed /etc/sudoers.d/mscp drop-in only sets `Defaults log_allowed`
# (sudo logging) — it does not touch timestamps, so it does not conflict.
#
# Gated to darwin.

return unless node[:platform] == "darwin"

user    = node[:setup][:user]
root    = node[:setup][:root]
staging = "#{root}/mac-sudo"

directory root do
  mode "755"
end

directory staging do
  mode "755"
end

# --- 1. global sudo timestamp (scoped to the apply user) ---------------------
sudoers_staging = "#{staging}/setup-sudo-timestamp"

file sudoers_staging do
  content <<~SUDOERS
    # Managed by cookbooks/mac-sudo — do not edit by hand.
    # Share #{user}'s sudo credential cache across all processes instead of
    # per-tty (macOS default tty_tickets), so a mitamae apply with many
    # `execute "sudo ..."` resources prompts at most once.
    Defaults:#{user} timestamp_type=global
  SUDOERS
  mode "644"
end

execute "install global sudo timestamp drop-in" do
  command "visudo -cf #{sudoers_staging} && " \
          "sudo install -m 0440 -o root -g wheel " \
          "#{sudoers_staging} /etc/sudoers.d/setup-sudo-timestamp"
  # test -e needs no sudo (/etc/sudoers.d is 0755); keeps dry-run prompt-free.
  # The drop-in is a stable one-liner; if its content ever changes, remove the
  # dest first so this re-installs (existence-based idempotency by design).
  not_if "test -e /etc/sudoers.d/setup-sudo-timestamp"
end

# --- 2. Touch ID for sudo (pam_tid) ------------------------------------------
pam_staging = "#{staging}/sudo_local"

file pam_staging do
  content <<~PAM
    # sudo_local: local config that survives system updates and is included by /etc/pam.d/sudo.
    # Managed by cookbooks/mac-sudo — enables Touch ID for sudo.
    auth       sufficient     pam_tid.so
  PAM
  mode "644"
end

execute "enable Touch ID for sudo (pam_tid)" do
  command "sudo install -m 0444 -o root -g wheel " \
          "#{pam_staging} /etc/pam.d/sudo_local"
  not_if "test -e /etc/pam.d/sudo_local"
end
