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

# Ensure npm is up to date, self-healing a prior interrupted global npm update.
#
# `npm upgrade -g npm` relinks the active mise-node install's bin/npm and
# bin/npx via an atomic rename (temp `.npm-XXXX` symlink -> `npm`). If a
# previous apply is interrupted mid-rename the canonical symlinks are gone and
# only `.npm-XXXX` / `.npx-XXXX` remnants remain; the mise `npm` shim then
# reports "No version is set for shim: npm" and every subsequent apply
# hard-fails here. Recreate the canonical symlinks and clear the remnants
# before upgrading so the step is self-recovering.
#
# The previous `test -x .../shims/npm` guard only checked that the shim file
# exists — mise creates that shim unconditionally, so it never detected a
# broken npm. The gate here is mise's presence; the repair block below handles
# the broken-npm case.
execute "repair + upgrade npm (mise node)" do
  user node[:setup][:user]
  command <<~'CMD'
    set -eu
    export PATH="$HOME/.local/share/mise/shims:$PATH"
    node_path="$($HOME/.local/bin/mise which node 2>/dev/null || true)"
    if [ -z "$node_path" ]; then
      echo "[nodejs] WARNING: mise node not resolvable; skipping npm repair/upgrade" >&2
      exit 0
    fi
    node_bin="$(dirname "$node_path")"
    if [ ! -e "$node_bin/npm" ] && [ -f "$node_bin/../lib/node_modules/npm/bin/npm-cli.js" ]; then
      ln -sf ../lib/node_modules/npm/bin/npm-cli.js "$node_bin/npm"
    fi
    if [ ! -e "$node_bin/npx" ] && [ -f "$node_bin/../lib/node_modules/npm/bin/npx-cli.js" ]; then
      ln -sf ../lib/node_modules/npm/bin/npx-cli.js "$node_bin/npx"
    fi
    rm -f "$node_bin"/.npm-* "$node_bin"/.npx-*
    npm upgrade -g npm
  CMD
  only_if "test -x $HOME/.local/bin/mise"
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
