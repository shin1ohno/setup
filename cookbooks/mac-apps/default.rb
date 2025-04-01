# frozen_string_literal: true

return if node[:platform] != "darwin"

%w(imageoptim
alacritty                       jetbrains-toolbox
kindle                          backblaze
zoom
balenaetcher                    monodraw
mqtt-explorer
charles                         obs
rapidapi                        launchcontrol
google-chrome
figma
firefox                         transmit
tidal                           karabiner-elements
via).each do |app|
  execute "brew reinstall --cask #{app}" do
    not_if "brew list | fgrep -q #{app}"
  end
end

execute "sudo -p 'enter password to install fdautil to /usr/local/bin/: ' cp -rp /Applications/LaunchControl.app/Contents/MacOS/fdautil /usr/local/bin/fdautil" do
  not_if { File.exist?("/usr/local/bin/fdautil") }
end

include_cookbook "roon"
