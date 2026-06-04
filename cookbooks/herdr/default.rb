# frozen_string_literal: true

# herdr - agent multiplexer that lives in your terminal (tmux replacement)
# https://herdr.dev  https://github.com/ogulcancelik/herdr
#
# Upstream ships bare prebuilt binaries (no archive, no .sha256 sidecar) on
# each GitHub release: herdr-{macos,linux}-{aarch64,x86_64}. The official
# installer (`curl -fsSL https://herdr.dev/install.sh | sh`) downloads the
# matching asset to ~/.local/bin/herdr and chmod +x — no integrity check.
# We mirror that placement but pin the version + verify sha256 ourselves so
# the install is reproducible across the fleet.
#
# Homebrew has a formula (homebrew-core) but it lags (0.6.4 vs 0.6.6) and
# builds from source via cargo + zig. mise has no registry entry. Direct
# binary download is the only path that gives the current version on both
# macOS and Linux without a Rust toolchain.

# Local vars, not top-level constants: mitamae loads every recipe into one
# Ruby namespace, so a generic `VERSION` would collide across cookbooks.
herdr_version = "0.6.6"

# sha256 of each release binary at v#{herdr_version}. On version bump, recompute:
#   for t in macos-aarch64 macos-x86_64 linux-aarch64 linux-x86_64; do
#     curl -fsSL ".../v<ver>/herdr-$t" | shasum -a 256
#   done
checksums = {
  "macos-aarch64" => "5437f87cac74db085bbc51619804fb61066f49f77c257f333331035bbe5e6c3f",
  "macos-x86_64"  => "f5078ee8baf98f2b7d89186065eacaba79b9139f6612fc5540927c819abb67c5",
  "linux-aarch64" => "6982375d0191016e26c8ce17342ea524788f6c3aeb4f3949d0015f51e33d16d2",
  "linux-x86_64"  => "0d0c0a39469434efb3630d7259f9f91463bad727a4c10ed1c40c06d30bc0eaac",
}

os = node[:platform] == "darwin" ? "macos" : "linux"
arch = case run_command("uname -m").stdout.strip
       when "arm64", "aarch64" then "aarch64"
       else "x86_64"
       end
target = "#{os}-#{arch}"
sha = checksums.fetch(target)
url = "https://github.com/ogulcancelik/herdr/releases/download/v#{herdr_version}/herdr-#{target}"

bin_dir = "#{node[:setup][:home]}/.local/bin"
herdr_path = "#{bin_dir}/herdr"

directory bin_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# Download + verify + install in one pipeline. Re-runs only when the on-disk
# binary is missing or reports a different version (so a VERSION bump above
# re-downloads, while a matching install is a no-op).
execute "install herdr #{herdr_version} (#{target})" do
  user node[:setup][:user]
  command <<~SH
    set -euo pipefail
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 '#{url}' -o "$tmp"
    echo '#{sha}  '"$tmp" | shasum -a 256 -c -
    install -m 0755 "$tmp" '#{herdr_path}'
  SH
  not_if "'#{herdr_path}' --version 2>/dev/null | grep -q '#{herdr_version}'"
end

# Managed config (converted from ~/.tmux.conf). Overwrites on content drift —
# the cookbook is the source of truth for herdr keybindings/theme.
directory "#{node[:setup][:home]}/.config/herdr" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

remote_file "#{node[:setup][:home]}/.config/herdr/config.toml" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  source "files/config.toml"
end

# `hr` — fzf-powered session switcher, the herdr analog of `tm` (cookbooks/fzf
# `fzf-advanced`). herdr is client/server, so there is no tmux switch-client vs
# attach-session split — a single `--session` / `session attach` works whether
# or not a client is already running.
#   hr <name>  → create-or-attach the named session (`herdr --session <name>`)
#   hr         → fzf-pick an existing session and attach; fall back to the
#                default session (`herdr`) when none is picked or none exist.
# Named `hr` (not `hd`) because `hd` collides with util-linux's hexdump alias
# (/usr/bin/hd) on Linux.
# Names are parsed from the tabular `session list` (skip header), mirroring the
# no-json-parser style of `tm`.
#
# Remove the orphaned `hd` profile script left on machines that applied the
# pre-rename cookbook (PR #425). Without this, `50-herdr-hd.sh` lingers and
# keeps the old colliding `hd()` function defined alongside the new `hr()`.
["sh", "fish"].each do |ext|
  file "#{node[:setup][:root]}/profile.d/50-herdr-hd.#{ext}" do
    action :delete
  end
end

add_profile "herdr-hr" do
  bash_content <<~'EOS'
  hr() {
    if [ -n "$1" ]; then
      herdr --session "$1"
      return
    fi
    session=$(herdr session list 2>/dev/null | awk 'NR>1 {print $1}' | fzf --exit-0) \
      && herdr session attach "$session" || herdr
  }
  EOS
end
