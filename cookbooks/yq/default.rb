# frozen_string_literal: true

include_cookbook "mise"

mise_tool "yq"

# Drop the Homebrew formula superseded by the mise-managed binary. No platform
# branch: the brew cache backing brew_formula? is written by cookbooks/homebrew
# (darwin-only), so off darwin the lookup reads a missing file, returns [], and
# this resource is skipped — the OS condition already lives in the guard.
package "yq" do
  action :remove
  only_if { brew_formula?("yq") }
end
