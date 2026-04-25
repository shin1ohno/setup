# frozen_string_literal: true

# Bump this constant to upgrade Tailscale on macOS. The recipe matches the
# installed version against /Applications/Tailscale.app's CFBundleShortVersionString
# and runs the .pkg installer when they differ.
TAILSCALE_VERSION = "1.96.5"

if node[:platform] == "darwin"
  pkg_dir = "#{node[:setup][:root]}/tailscale"
  pkg_name = "Tailscale-#{TAILSCALE_VERSION}-macos.pkg"
  pkg_path = "#{pkg_dir}/#{pkg_name}"
  pkg_url = "https://pkgs.tailscale.com/stable/#{pkg_name}"

  directory pkg_dir do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
  end

  execute "download Tailscale #{TAILSCALE_VERSION} pkg + sha256" do
    user node[:setup][:user]
    # Tailscale's .sha256 file contains only the bare hash (no filename),
    # so build a `<hash>  <filename>` line for `shasum -c` on the fly.
    command <<~SH
      set -e
      curl -fsSL #{pkg_url} -o #{pkg_path}
      curl -fsSL #{pkg_url}.sha256 -o #{pkg_path}.sha256
      cd #{pkg_dir}
      printf '%s  %s\\n' "$(cat #{pkg_name}.sha256)" "#{pkg_name}" | shasum -a 256 -c -
    SH
    not_if "defaults read /Applications/Tailscale.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null | grep -q '^#{TAILSCALE_VERSION}$'"
  end

  execute "install Tailscale #{TAILSCALE_VERSION}" do
    user node[:setup][:system_user]
    command "installer -pkg #{pkg_path} -target /"
    not_if "defaults read /Applications/Tailscale.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null | grep -q '^#{TAILSCALE_VERSION}$'"
  end

  # Clean up the legacy `tailscale` cask installed by mac-apps in earlier
  # revisions. Safe to run when the cask is not present.
  execute "brew uninstall --cask tailscale" do
    only_if { brew_cask?("tailscale") }
  end
else
  remote_file "#{node[:setup][:root]}/tailscale.sh" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    source "files/install.sh"
  end

  execute "#{node[:setup][:root]}/tailscale.sh" do
    not_if "which tailscale"
  end
end
