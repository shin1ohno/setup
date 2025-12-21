# frozen_string_literal: true

# AltServer - Sideload apps to iOS devices
# https://altstore.io/

return if node[:platform] != "darwin"

execute "brew reinstall --cask altserver" do
  not_if "brew list | fgrep -q altserver"
end
