# frozen_string_literal: true

neovim_root = "#{node[:setup][:root]}/neovim"

if node[:platform] == "ubuntu"
  execute "apt-get update" do
    user node[:setup][:install_user]
  end

  # Install dependencies
  %w(ninja-build gettext libtool libtool-bin autoconf automake cmake g++ pkg-config unzip curl).each do |pkg|
    package pkg do
      user node[:setup][:install_user]
    end
  end

  execute "mkdir -p #{neovim_root}" do
    user node[:setup][:install_user]
    not_if "test -d #{neovim_root}"
  end

  execute "Download the latest stable neovim" do
    command "curl -OL https://github.com/neovim/neovim/archive/refs/tags/stable.tar.gz && tar xfzv stable.tar.gz"
    cwd neovim_root
    not_if "test -d #{neovim_root}/neovim-stable"
  end

  execute "build and install neovim" do
    command <<-EOH
      make CMAKE_BUILD_TYPE=RelWithDebInfo
      sudo make install
    EOH
    cwd "#{neovim_root}/neovim-stable"
    not_if "which nvim"
  end
else
  package "neovim"
end
