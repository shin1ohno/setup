# frozen_string_literal: true

# Bump this constant to upgrade Neovim. Mitamae detects the installed version
# via `nvim --version` and triggers a rebuild when it differs.
NVIM_VERSION = "v0.11.4"

neovim_root = "#{node[:setup][:root]}/neovim"
nvim_source_dir = "neovim-#{NVIM_VERSION.delete_prefix('v')}"

if node[:platform] == "ubuntu"
  execute "apt-get update" do
    user node[:setup][:system_user]
  end

  # Install dependencies
  %w(ninja-build gettext libtool libtool-bin autoconf automake cmake g++ pkg-config unzip curl).each do |pkg|
    package pkg do
      user node[:setup][:system_user]
    end
  end

  execute "mkdir -p #{neovim_root}" do
    user node[:setup][:system_user]
    not_if "test -d #{neovim_root}"
  end

  execute "Download Neovim #{NVIM_VERSION}" do
    command "curl -OL https://github.com/neovim/neovim/archive/refs/tags/#{NVIM_VERSION}.tar.gz && tar xfzv #{NVIM_VERSION}.tar.gz"
    cwd neovim_root
    not_if "test -d #{neovim_root}/#{nvim_source_dir}"
  end

  execute "Build and install Neovim #{NVIM_VERSION}" do
    command <<-EOH
      make CMAKE_BUILD_TYPE=RelWithDebInfo
      sudo make install
    EOH
    cwd "#{neovim_root}/#{nvim_source_dir}"
    not_if "nvim --version 2>/dev/null | head -1 | grep -q 'NVIM #{NVIM_VERSION}'"
  end
else
  package "neovim"
end

add_profile "editor" do
  priority 50
  bash_content <<~BASH
    export EDITOR="nvim"
    export VISUAL="nvim"
  BASH
end
