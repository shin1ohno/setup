# frozen_string_literal: true

# Core role: Essential command-line tools and basic system setup
# This role provides fundamental tools needed for command-line operations

# Basic directory setup
[
  node[:setup][:root],
  "#{node[:setup][:root]}/profile.d",
  "#{node[:setup][:root]}/bin",
].each do |dir|
  directory dir do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    action :create
  end
end

template "#{node[:setup][:root]}/profile" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  source "templates/profile"
end

# Package manager
include_cookbook "homebrew" if node[:platform] == "darwin"

# Essential system tools
include_cookbook "tree"
include_cookbook "zsh"
include_cookbook "git"
include_cookbook "ssh"
include_cookbook "wget"

# Modern CLI enhancement tools
include_cookbook "fzf"
include_cookbook "fzf-tab"
include_cookbook "zoxide"
include_cookbook "bat"
include_cookbook "autojump"
include_cookbook "ripgrep"
include_cookbook "fd"

# Shell and terminal enhancements
include_cookbook "dot-zsh"
include_cookbook "tmux"
include_cookbook "dot-tmux"
include_cookbook "fonts"
include_cookbook "dot-config-alacritty"
include_cookbook "neofetch"
include_cookbook "pbcopy" # OSC 52 clipboard for Linux

# Security and encryption
include_cookbook "gnupg"
include_cookbook "envchain" if node[:platform] == "darwin"
