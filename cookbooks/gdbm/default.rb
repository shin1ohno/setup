# frozen_string_literal: true

# `gdbm-1.14` is the pre-rename Homebrew formula, superseded by the
# versionless `gdbm` below. The brew_formula? guard replaces the old
# `if node[:platform] == "darwin"` wrapper: the brew cache is empty on Linux
# (cookbooks/homebrew is darwin-only and is what populates it), so the removal
# is a no-op there without a platform branch — same shape as the brew cleanup
# arms in cookbooks/haskell.
package "gdbm-1.14" do
  action :remove
  only_if { brew_formula?("gdbm-1.14") }
end

install_package "gdbm" do
  darwin "gdbm"
  ubuntu "libgdbm-dev"
  arch "gdbm"
end
