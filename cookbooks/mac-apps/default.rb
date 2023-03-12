# frozen_string_literal: true

return if node[:platform] != "darwin"

%w(aerial                       imageoptim
alacritty                       jetbrains-toolbox
kindle                          backblaze
around                          zoom
balenaetcher                    monodraw
mqtt-explorer                   lunar
charles                         obs
rapidapi                        launchcontrol
docker                          ron
figma                           syntax-highlight
firefox                         transmit
tidal
via                             tableau
grammarly).each do |app|
  execute "brew reinstall --cask #{app}" do
    not_if "brew list | fgrep -q #{app}"
  end
end

execute "sudo -p 'enter password to install fdautil to /usr/local/bin/: ' cp -rp /Applications/LaunchControl.app/Contents/MacOS/fdautil /usr/local/bin/fdautil" do
  not_if { File.exist?("/usr/local/bin/fdautil") }
end

include_cookbook "roon"
include_cookbook "roon-server"
