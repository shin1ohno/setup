include_cookbook "mise"

mise_tool "fastfetch"

# Drop the Homebrew neofetch superseded by the mise-managed fastfetch. No
# platform branch: the brew cache backing brew_formula? is written by
# cookbooks/homebrew (darwin-only), so off darwin the lookup reads a missing
# file, returns [], and this resource is skipped — the OS condition already
# lives in the guard.
package "neofetch" do
  action :remove
  only_if { brew_formula?("neofetch") }
end
