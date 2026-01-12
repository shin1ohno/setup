# frozen_string_literal: true

# AltServer - Sideload apps to iOS devices
# https://altstore.io/
#
# This cookbook installs:
# - AltServer: macOS companion app for AltStore
# - jitterbugpair: CLI tool to generate pairing files for JIT debugging

return if node[:platform] != "darwin"

# Install AltServer via Homebrew Cask
execute "brew reinstall --cask altserver" do
  not_if "brew list | fgrep -q altserver"
end

# Install jitterbugpair from GitHub releases
# https://github.com/osy/Jitterbug
jitterbugpair_version = "1.3.1"
jitterbugpair_path = "#{node[:homebrew][:prefix]}/bin/jitterbugpair"

execute "install jitterbugpair" do
  command <<~BASH
    cd /tmp
    curl -L -o jitterbugpair.zip "https://github.com/osy/Jitterbug/releases/download/v#{jitterbugpair_version}/jitterbugpair-macos-universal.zip"
    unzip -o jitterbugpair.zip
    chmod +x jitterbugpair
    mv jitterbugpair #{jitterbugpair_path}
    rm -f jitterbugpair.zip
  BASH
  not_if "test -f #{jitterbugpair_path}"
end
