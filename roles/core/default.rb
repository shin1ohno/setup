# frozen_string_literal: true

# Core role: Essential command-line tools and basic system setup
# This role provides fundamental tools needed for command-line operations

# NOTE: the directory/profile bootstrap, homebrew, and the auth-critical
# cookbooks (git, ssh, ssh-keys) moved to roles/foundation, which runs BEFORE
# this role (see roles/foundation/default.rb and darwin.rb / linux.rb). By the
# time core runs, node[:setup][:root]/profile.d and git/ssh are already in place.

# Essential system tools
include_cookbook "tree"
include_cookbook "zsh"
include_cookbook "wget"

# Modern CLI enhancement tools
include_cookbook "fzf"
include_cookbook "fzf-tab"
include_cookbook "zoxide"
include_cookbook "bat"
include_cookbook "ripgrep"
include_cookbook "fd"

# Shell and terminal enhancements
include_cookbook "dot-zsh"
include_cookbook "tmux"
include_cookbook "dot-tmux"
include_cookbook "herdr"
include_cookbook "fonts"
include_cookbook "dot-config-alacritty"
include_cookbook "dot-config-ghostty" if node[:platform] == "darwin"
include_cookbook "dot-config-starship" # aws symbol width fix; cross-platform
include_cookbook "fastfetch"
include_cookbook "pbcopy" unless node[:platform] == "darwin" # OSC 52 clipboard, Linux-only

# Security and encryption
include_cookbook "gnupg"
include_cookbook "envchain" if node[:platform] == "darwin"
