# frozen_string_literal: true

include_recipe "cookbooks/functions/default"

# node[:setup] / node[:homebrew] are resolved once by cookbooks/host-profile
# (included via functions/default above) — no per-entry reverse_merge needed.

# Cut sudo prompts FIRST so every sudo-using resource below shares one auth.
# (macOS tty_tickets re-prompts per specinfra subshell; mac-sudo switches the
# apply user to a global timestamp + enables Touch ID.)
include_cookbook "mac-sudo"

# Foundation: ssh keys / AWS / gh credentials FIRST, before heavy installs.
# (dirs/profile bootstrap + homebrew + git + ssh + awscli + ssh-keys)
include_role "foundation"

# Include modular roles
include_role "core"
include_role "programming"
include_role "llm"
include_role "network"
include_role "extras"

# Legacy roles for backwards compatibility
include_role "manage" # Managed projects setup

# macOS-specific client setup (integrated from client role)
include_cookbook "mac-settings"
include_cookbook "mac-apps"
include_cookbook "macism"
include_cookbook "altserver"
include_cookbook "zed"
include_cookbook "dot-config-zed"
include_cookbook "gpg-backup"
include_cookbook "edge-agent"
include_cookbook "elastic-agent"
include_cookbook "macos-hub"

