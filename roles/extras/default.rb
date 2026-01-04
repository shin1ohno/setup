# frozen_string_literal: true

# Extras role: Additional specialized tools and applications
# This role includes development tools, editors, and other specialized utilities

# Development and productivity tools
include_cookbook "terraform"
include_cookbook "ctags"
include_cookbook "neovim"
include_cookbook "dot-config-nvim"
include_cookbook "lazygit"

# File utilities and knowledge tools
include_cookbook "imgcat"
include_cookbook "skicka"
include_cookbook "tnef"
include_cookbook "zk"

# Containerization and virtualization
include_cookbook "docker-engine" unless node[:platform] == "darwin"

