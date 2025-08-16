# frozen_string_literal: true

# Node.js installation using mise
# This cookbook replaces volta-based Node.js management with mise

# Ensure mise is installed
include_cookbook "mise"

# Install Node.js versions configured in node attributes
node[:nodejs][:versions].each do |version|
  execute "$HOME/.local/bin/mise install node@#{version}" do
    user node[:setup][:user]
    not_if "$HOME/.local/bin/mise list node | grep -q '#{version}'"
  end
end

# Set default Node.js version to the first in the list
default_version = node[:nodejs][:versions].first
execute "$HOME/.local/bin/mise use --global node@#{default_version}" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list node | grep -q '\\* #{default_version}'"
end

# Install yarn globally using corepack
execute "export PATH=$HOME/.local/share/mise/shims:$PATH && corepack enable" do
  user node[:setup][:user]
  not_if "which yarn"
end

# Install pnpm globally using corepack
execute "export PATH=$HOME/.local/share/mise/shims:$PATH && corepack enable pnpm" do
  user node[:setup][:user]
  not_if "which pnpm"
end

# Ensure npm is up to date
execute "export PATH=$HOME/.local/share/mise/shims:$PATH && npm upgrade -g npm" do
  user node[:setup][:user]
end

# Add Node.js related environment setup
add_profile "nodejs" do
  bash_content <<~BASH
    # Node.js managed by mise
    export PATH="$HOME/.local/share/mise/shims:$PATH"
    
    # Enable corepack for yarn and pnpm
    export COREPACK_ENABLE_STRICT=0
  BASH
  priority 70
end
