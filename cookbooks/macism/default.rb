# frozen_string_literal: true

return unless node[:platform] == "darwin"

# macism is a Swift tool — `mise use go:github.com/laishulu/macism` does
# not work (the repo is not a Go module). Upstream publishes raw binaries
# `macism-arm64` and `macism-x86_64` on each GitHub release, with no
# darwin/macos string in the asset name (so mise's github backend
# auto-detection can't pick the right asset either). Install via direct
# curl to /usr/local/bin/macism.
arch = node[:homebrew][:machine] == "arm64" ? "arm64" : "x86_64"
macism_url = "https://github.com/laishulu/macism/releases/latest/download/macism-#{arch}"

execute "download macism (#{arch})" do
  user node[:setup][:system_user]
  command "curl -fsSL '#{macism_url}' -o /usr/local/bin/macism && chmod 0755 /usr/local/bin/macism"
  not_if "test -x /usr/local/bin/macism"
end

# Cleanup the legacy brew install + tap.
package "macism" do
  action :remove
  only_if { brew_formula?("macism") }
end

execute "brew untap laishulu/homebrew" do
  only_if { brew_tap?("laishulu/homebrew") }
end
