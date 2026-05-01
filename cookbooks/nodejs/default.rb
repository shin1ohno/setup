# frozen_string_literal: true

# Node.js installation using mise
# This cookbook replaces volta-based Node.js management with mise

# Ensure mise is installed
include_cookbook "mise"

mise_tool "node" do
  versions node[:nodejs][:versions]
end

# Install yarn globally using corepack. `which yarn` fails inside the
# `sudo -u <user>` wrap because the wrapped shell's PATH lacks the mise
# shim dir even when the parent mitamae process has it. Test the shim
# file directly via Ruby File.exist? — no shell wrap involved.
execute "export PATH=$HOME/.local/share/mise/shims:$PATH && corepack enable" do
  user node[:setup][:user]
  not_if { File.exist?("#{node[:setup][:home]}/.local/share/mise/shims/yarn") }
end

# Install pnpm globally using corepack
execute "export PATH=$HOME/.local/share/mise/shims:$PATH && corepack enable pnpm" do
  user node[:setup][:user]
  not_if { File.exist?("#{node[:setup][:home]}/.local/share/mise/shims/pnpm") }
end

# Ensure npm is up to date
execute "export PATH=$HOME/.local/share/mise/shims:$PATH && npm upgrade -g npm" do
  user node[:setup][:user]
  only_if "test -x $HOME/.local/share/mise/shims/npm"
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
