# frozen_string_literal: true

# Node.js installation using mise
# This cookbook replaces volta-based Node.js management with mise

# Ensure mise is installed
include_cookbook "mise"

mise_tool "node" do
  versions node[:nodejs][:versions]
end

# yarn and pnpm are standalone mise tools, not corepack shims. Node.js
# stopped bundling corepack in v25 (installs/node/26.x/bin has no `corepack`;
# 24.x still has it), so the moment `lts` resolved to 26 the former
# `corepack enable` step failed on every apply with
# "No version is set for shim: corepack". Installing them directly also
# decouples them from whichever node version is active, so a later lts
# bump cannot break them again.
mise_tool "yarn"
mise_tool "pnpm"

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
  BASH
  priority 70
end
