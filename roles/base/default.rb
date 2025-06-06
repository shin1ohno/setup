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
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  source "templates/profile"
end

node.reverse_merge!(
  rbenv: {
    root: "#{ENV['HOME']}/.rbenv",
  },
  go: {
    versions: %w(go1.22.3 go1.21.8)
  },
  nodejs: {
    versions: %w(18 20 21)
  },
  python: {
    versions: %w(3.12.2 3.11.8)
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
    global_version: "3.3",
    global_gems: %w(bundler itamae ed25519 bcrypt_pbkdf)
  }
)
include_cookbook "gdbm"
include_cookbook "berkeley-db"
include_cookbook "libffi"
include_cookbook "libyaml"
include_cookbook "readline"
include_cookbook "ncurses"
include_cookbook "zlib"
include_cookbook "envchain" if node[:platform] == "darwin"
include_cookbook "awscli"
include_cookbook "gcloud-cli"
include_cookbook "rbenv"
include_cookbook "ruby33"
include_cookbook "ruby32"

include_cookbook "rust"
include_cookbook "nodejs"
include_cookbook "haskell"
include_cookbook "golang"
include_cookbook "uv"
include_cookbook "mise"

include_cookbook "mosh"
include_cookbook "skicka"
include_cookbook "tnef"
include_cookbook "lazygit"
include_cookbook "dot-zsh"
include_cookbook "tmux"
include_cookbook "dot-tmux"
include_cookbook "fonts"
include_cookbook "python"
include_cookbook "ctags"
include_cookbook "neovim"
include_cookbook "dot-config-nvim"
include_cookbook "fd"
include_cookbook "fzf"
include_cookbook "fzf-tab"
include_cookbook "zoxide"
include_cookbook "bat"
include_cookbook "autojump"
include_cookbook "ripgrep"
include_cookbook "wget"
include_cookbook "ssh"
include_cookbook "dot-config-alacritty"
include_cookbook "neofetch"
include_cookbook "speedtest-cli"
include_cookbook "rclone"
include_cookbook "iperf3"
include_cookbook "gnupg"
include_cookbook "zk"
