# frozen_string_literal: true
#
# Starship prompt configuration. The `starship` cookbook installs the binary
# and cookbooks/sheldon activates it; this cookbook deploys a minimal
# ~/.config/starship.toml that overrides only the `aws` module symbol.
#
# Rationale: the default aws symbol "☁️" (cloud + VS16) is measured as width 2
# by tmux but width 1 by zsh/glibc wcwidth, desyncing the cursor and doubling
# characters on tab-completion redraw inside tmux. Replacing it with a width-1
# Nerd Font cloud glyph (nf-fa-cloud) makes the width consistent across
# zsh / tmux / Ghostty / Zed. See files/starship.toml for the full writeup.
#
# Cross-platform: starship runs on both darwin (Ghostty) and linux LXC/dev
# hosts (pro-dev over SSH+tmux), and the doubling occurs on both, so this is
# NOT darwin-gated. Included at roles/core unconditionally.

directory "#{node[:setup][:home]}/.config" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

remote_file "#{node[:setup][:home]}/.config/starship.toml" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  source "files/starship.toml"
end
