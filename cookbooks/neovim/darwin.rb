# frozen_string_literal: true
#
# neovim, darwin half: the mise-managed prebuilt binary.
#
# Split rather than a platform_value because linux.rb builds from source
# against apt-installed toolchain packages — an entirely different resource
# set, not a different value. This is the arm the pre-split default.rb reached
# through its catch-all `else`.
include_cookbook "mise"

mise_tool "neovim"

# Drop the Homebrew formula superseded by the mise-managed binary.
package "neovim" do
  action :remove
  only_if { brew_formula?("neovim") }
end

include_recipe "common"
