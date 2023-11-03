# frozen_string_literal: true

neovim_root = "#{node[:setup][:root]}/neovim"

if node[:platform] == "ubuntu"
  execute "apt-get update" do
    user "root"
  end

  # Install dependencies
  %w(ninja-build gettext libtool libtool-bin autoconf automake cmake g++ pkg-config unzip curl).each do |pkg|
    package pkg do
      user "root"
    end
  end

  execute "mkdir -p #{neovim_root}" do
    user node[:setup][:user]
    not_if "test -d #{neovim_root}"
  end

  execute "Download the latest stable neovim" do
    command "curl -O https://github.com/neovim/neovim/releases/download/stable/nvim-linux64.tar.gz"
    cwd neovim_root
    not_if "test -d #{neovim_root}/nvim-linux64"
  end

  execute "build and install neovim" do
    command <<-EOH
      make CMAKE_BUILD_TYPE=RelWithDebInfo
      sudo make install
    EOH
    cwd neovim_root
    not_if "which nvim"
  end
else
  package "neovim"
end
