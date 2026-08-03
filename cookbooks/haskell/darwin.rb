# frozen_string_literal: true
#
# haskell, darwin half: stack comes from mise (GitHub backend) and the
# pre-mise Homebrew formulae get cleaned up; ghcup itself is bootstrapped by
# the shared ghcup.rb in between, so the brew `ghcup` removal still runs after
# the installer has taken over. Linux installs stack from its own upstream
# script instead (cookbooks/haskell/linux.rb).
include_cookbook "mise"
mise_tool "commercialhaskell/stack" do
  backend "github"
end
package "haskell-stack" do
  action :remove
  only_if { brew_formula?("haskell-stack") }
end

include_recipe "ghcup"

package "ghcup" do
  action :remove
  only_if { brew_formula?("ghcup") }
end

include_recipe "profile"
