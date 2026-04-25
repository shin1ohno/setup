# frozen_string_literal: true

return unless node[:platform] == "darwin"

include_cookbook "mise"
include_cookbook "golang"

mise_tool "github.com/laishulu/macism" do
  backend "go"
end

package "macism" do
  action :remove
  only_if { brew_formula?("macism") }
end

execute "brew untap laishulu/homebrew" do
  only_if { brew_tap?("laishulu/homebrew") }
end
