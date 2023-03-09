# frozen_string_literal: true

return if node[:platform] != "darwin"

%w(aerial                          imageoptim
alacritty                       jetbrains-toolbox
kindle
around
balenaetcher                    monodraw
mqtt-explorer
charles                         obs
rapidapi
docker                          roon
figma                           syntax-highlight
firefox                         transmit
grammarly).each do |app|
  execute "brew reinstall --cask #{app}" do
    not_if "brew list | fgrep -q #{app}"
  end
end
