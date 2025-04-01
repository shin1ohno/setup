# frozen_string_literal: true

return if node[:platform] != "darwin"

%w(
  alacritty                 balenaetcher
  backblaze                 charles
  claude                    figma
  firefox                   ghostty
  google-chrome             imageoptim
  iterm2                    jetbrains-toolbox
  karabiner-elements        kindle
  launchcontrol             monodraw
  mqtt-explorer             obsidian
  obs                       rapidapi
  tailscale                 tidal
  transmit                  via
  zoom
).each do |app|
  execute "brew reinstall --cask #{app}" do
    not_if "brew list | fgrep -q #{app}"
  end
end

execute "sudo -p 'enter password to install fdautil to /usr/local/bin/: ' cp -rp /Applications/LaunchControl.app/Contents/MacOS/fdautil /usr/local/bin/fdautil" do
  not_if { File.exist?("/usr/local/bin/fdautil") }
end

include_cookbook "roon"
