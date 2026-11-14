# frozen_string_literal: true

# Herdr desktop app (Herdr UI) for macOS. It is built on herdr-core
# (cookbooks/herdr-core) and sits BESIDE the Herdr 1 TUI (cookbooks/herdr),
# which keeps its own binary, configuration and panes.
#
# files/install.sh is a verbatim copy of upstream's installer so the exact script
# that runs is in git and reviewable, not a `curl | sh` at apply time:
#   source:  https://releases.herdr.dev/app/install.sh
#   fetched: 2026-11-10 (6089 bytes)
#   sha256:  49e2b998ee311e131997447542869b99f888ef6c3cd4610abfaa97f4f44b52eb
# To refresh the copy, download it, read the diff against files/install.sh, then
# replace the file and update the three lines above.
#
# On macOS the script reads app/latest.json, downloads the release tarball,
# checks its sha256 against that manifest, installs ~/Applications/Herdr.app and
# links ~/.local/bin/herdr-app. A Developer ID signed bundle is verified with
# codesign --verify --deep --strict and left untouched; an ad hoc build is re-signed
# ad hoc with PATH added to its Info.plist. It installs herdr-core only when none
# exists; roles/core runs earlier in darwin.rb, so that branch does not fire here.
#
# The version is NOT pinned. The first apply installs the latest release and the
# app updates itself afterwards. The script replaces the whole bundle on every
# run, so the guard is "Herdr.app is absent" rather than a version comparison
# (which would downgrade a self-updated app on the next apply).
#
# Apple silicon only: upstream publishes no Intel macOS build and the script
# exits 1 there, which would abort the whole apply, so other machines skip with a
# WARN. Linux hosts never include this cookbook (platform marker + darwin.rb).

apple_silicon = %w(arm64 aarch64).include?(node[:hw][:machine])

if apple_silicon
  installer = "#{node[:setup][:root]}/herdr-app-install.sh"
  app_in_user_dir = "#{node[:setup][:home]}/Applications/Herdr.app"

  remote_file installer do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    source "files/install.sh"
  end

  # No `user`: mitamae already runs as the operator, and `user` would route the
  # command through `sudo -H -u` and drop the environment (HOME, PATH).
  execute "install Herdr app" do
    command installer
    not_if "test -d /Applications/Herdr.app || test -d '#{app_in_user_dir}'"
  end
else
  MItamae.logger.warn(
    "[herdr-app] skipped: hw.machine=#{node[:hw][:machine]}; " \
    "upstream ships the Herdr app for Apple silicon (arm64) only.",
  )
end
