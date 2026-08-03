# frozen_string_literal: true

# macOS Tailscale tracks the LATEST stable release, resolved dynamically from
# pkgs.tailscale.com at converge time — no pinned version. The macOS app
# self-updates via Sparkle, so a fixed pin caused a downgrade tug-of-war: the
# app would auto-update (e.g. 1.98.5), then a re-apply would reinstall the
# older pinned .pkg, leaving the installed app OLDER than the already-loaded
# VPN system extension → "Tailscale Version Mismatch". Tracking latest +
# upgrade-only (never downgrade) removes that class entirely.
#
# Latest macOS version comes from the manifest's `MacZipsVersion` /
# `MacZips.universal-package` (the generic `Version` field is the CLI release,
# which lags the macOS app — e.g. 1.98.4 CLI vs 1.98.5 macOS, and the 1.98.4
# macOS .pkg does not exist). We read the pkg filename straight from the
# manifest with grep (no python — keeps it off the sudo-sanitized PATH).
TAILSCALE_MANIFEST_URL = "https://pkgs.tailscale.com/stable/?mode=json"

pkg_dir = "#{node[:setup][:root]}/tailscale"
# Fixed local filename (the upstream version is dynamic); the latest .pkg is
# downloaded here only when an upgrade is actually needed.
pkg_path = "#{pkg_dir}/Tailscale-latest-macos.pkg"
info_plist = "/Applications/Tailscale.app/Contents/Info.plist"

directory pkg_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

execute "download latest Tailscale macOS pkg" do
  user node[:setup][:user]
  # Resolve the latest macOS .pkg name from the manifest, download it and its
  # .sha256 sidecar (bare hash → build a `<hash>  <filename>` line for
  # `shasum -c`), and verify.
  command <<~SH
    set -euo pipefail
    pkg_name="$(curl -fsSL '#{TAILSCALE_MANIFEST_URL}' | grep -oE 'Tailscale-[0-9.]+-macos\\.pkg' | head -1)"
    [ -n "$pkg_name" ] || { echo "tailscale: could not resolve latest macOS pkg from manifest" >&2; exit 1; }
    url="https://pkgs.tailscale.com/stable/${pkg_name}"
    curl -fsSL "$url" -o '#{pkg_path}'
    curl -fsSL "${url}.sha256" -o '#{pkg_path}.sha256'
    printf '%s  %s\\n' "$(cat '#{pkg_path}.sha256')" "$(basename '#{pkg_path}')" \\
      | (cd '#{pkg_dir}' && shasum -a 256 -c -)
  SH
  # Skip when: (a) the manifest is unreachable (offline → stay safe, no error),
  # or (b) the installed app is already >= latest (upgrade-only; never
  # downgrade, never reinstall the same version).
  not_if <<~SH
    latest="$(curl -fsSL '#{TAILSCALE_MANIFEST_URL}' 2>/dev/null | grep -oE 'Tailscale-[0-9.]+-macos\\.pkg' | head -1 | sed -E 's/^Tailscale-([0-9.]+)-macos\\.pkg$/\\1/')"
    installed="$(defaults read #{info_plist} CFBundleShortVersionString 2>/dev/null)"
    [ -z "$latest" ] && exit 0
    [ -n "$installed" ] && [ "$(printf '%s\\n%s\\n' "$latest" "$installed" | sort -V | tail -1)" = "$installed" ]
  SH
  notifies :run, "execute[install latest Tailscale macOS pkg]"
end

execute "install latest Tailscale macOS pkg" do
  user node[:setup][:system_user]
  command "installer -pkg #{pkg_path} -target /"
  action :nothing
  only_if "test -f #{pkg_path}"
end

# Clean up the legacy `tailscale` cask installed by mac-apps in earlier
# revisions. Safe to run when the cask is not present.
execute "brew uninstall --cask tailscale" do
  only_if { brew_cask?("tailscale") }
end
