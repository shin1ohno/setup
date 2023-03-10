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
docker                          roon
figma                           syntax-highlight
firefox                         transmit
tidal
via                             tableau
grammarly).each do |app|
  execute "brew reinstall --cask #{app}" do
    not_if "brew list | fgrep -q #{app}"
  end
end
