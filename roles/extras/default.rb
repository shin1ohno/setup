# frozen_string_literal: true

# Extras role: Additional specialized tools and applications
# This role includes development tools, editors, and other specialized utilities

# Development and productivity tools
include_platform_cookbook "terraform"
include_cookbook "ctags"
include_platform_cookbook "neovim"
include_cookbook "dot-config-nvim"
# im-select is the darwin-only tail dot-config-nvim used to carry inline; it
# stays adjacent so the resource order on darwin is unchanged.
include_cookbook "im-select" if node[:platform] == "darwin"
include_cookbook "imagemagick"
include_cookbook "lazygit"

# Google Workspace CLI
include_cookbook "gws"

# File utilities and knowledge tools
include_cookbook "imgcat"
include_cookbook "skicka"
include_cookbook "tnef"
include_platform_cookbook "zk"

# Presentation
include_cookbook "slidev"

# Containerization and virtualization
include_cookbook "docker-engine" unless node[:platform] == "darwin"

