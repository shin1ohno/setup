# frozen_string_literal: true

# Zed — code editor. macOS only.
# https://zed.dev
#
# Installed via Homebrew cask. No mise tool exists for Zed. A Linux
# variant via Zed's official install.sh script is intentionally out of
# scope here — bare-metal `pro` and the developer LXCs don't run GUI
# applications.
#
# EDITOR / VISUAL env vars are left untouched (nvim cookbook owns those
# at priority 50) so CLI git operations continue using nvim.

return if node[:platform] != "darwin"

execute "brew install --cask zed" do
  not_if { brew_cask?("zed") }
end
