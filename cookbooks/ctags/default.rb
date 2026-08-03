# frozen_string_literal: true

# universal-ctags/ctags upstream publishes only source tarballs on GitHub
# releases (no prebuilt darwin binary), so mise's github backend can't install
# it — brew's universal-ctags formula is the standard darwin install path.
# Debian/Ubuntu ship the same project under the same name; arch's package is
# plain `ctags`, which is what the old catch-all `else` arm installed there.
install_package "ctags" do
  darwin "universal-ctags"
  ubuntu "universal-ctags"
  arch   "ctags"
end

# Drop the legacy Homebrew `ctags` formula superseded by universal-ctags. No
# platform branch: the brew cache backing brew_formula? is written by
# cookbooks/homebrew (darwin-only), so off darwin the lookup reads a missing
# file, returns [], and this resource is skipped — the OS condition already
# lives in the guard.
package "ctags" do
  action :remove
  only_if { brew_formula?("ctags") }
end
