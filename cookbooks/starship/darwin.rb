# frozen_string_literal: true
#
# Starship cross-shell prompt, darwin half: the Homebrew formula. Activated by
# cookbooks/sheldon's profile entry -- this cookbook only installs the binary,
# so the prompt and the plugin lifecycle stay co-located there.
#
# Split rather than a platform_value because Ubuntu has no starship package at
# all and installs through the upstream script instead (cookbooks/starship/
# linux.rb) -- different resources, not a different value.
package "starship" do
  not_if { brew_formula?("starship") }
end
