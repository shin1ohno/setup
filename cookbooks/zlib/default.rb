# frozen_string_literal: true

# Linux-only (see the `platform` marker): macOS builds Ruby against the zlib
# that ships with the SDK, so darwin never installed a package here — the old
# body was an `if node[:platform] != "darwin"` wrapper around this single
# resource. roles/programming skips the include on darwin, and a stray
# cross-OS include now raises from include_cookbook instead of silently
# no-opping.
install_package "zlib" do
  ubuntu "zlib1g-dev"
  arch "zlib"
end
