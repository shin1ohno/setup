# frozen_string_literal: true

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
  owner node[:setup][:uer]
  group node[:setup][:group]
  mode "644"
  source "templates/profile"
end

node.reverse_merge!(
  rbenv: {
    root: "#{ENV['HOME']}/.rbenv",
  },
  go: {
    versions: %w(go1.21.3 go1.20.9)
  },
  nodejs: {
    versions: %w(16 17 18 19)
  },
  python: {
    versions: %w(3.9.9 3.12.0)
  }
)


include_cookbook "homebrew" if node[:platform] == "darwin"

include_cookbook "tree"
include_cookbook "zsh"

include_cookbook "build-essential" unless node[:platform] == "darwin"
include_cookbook "jdk"
include_cookbook "git"
include_cookbook "terraform"

# for ruby
node.reverse_merge!(
  rbenv: {
    global_version: "3.2",
    global_gems: %w(bundler rubocop rubocop-rails rubocop-minitest rubocop-packaging rubocop-performance itamae ed25519 bcrypt_pbkdf)
  }
)
include_cookbook "gdbm"
include_cookbook "berkeley-db"
include_cookbook "libffi"
include_cookbook "libyaml"
include_cookbook "openssl"
include_cookbook "readline"
include_cookbook "ncurses"
include_cookbook "zlib"
include_cookbook "envchain" if node[:platform] == "darwin"
include_cookbook "awscli"
include_cookbook "rbenv"
include_cookbook "ruby32"
include_cookbook "ruby31"

include_cookbook "rust"
include_cookbook "nodejs"
include_cookbook "haskell"
include_cookbook "golang"

include_cookbook "lazygit"
include_cookbook "dot-zsh"
include_cookbook "tmux"
include_cookbook "dot-tmux"
include_cookbook "fonts"
include_cookbook "python"
include_cookbook "ctags"
include_cookbook "neovim"
include_cookbook "dot-config-nvim"
include_cookbook "thefuck"
include_cookbook "fd"
include_cookbook "fzf"
include_cookbook "bat"
include_cookbook "autojump"
include_cookbook "ripgrep"
include_cookbook "enhancd"
include_cookbook "gotop"
include_cookbook "ssh"
include_cookbook "dot-config-alacritty"
