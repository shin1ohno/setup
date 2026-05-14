# frozen_string_literal: true

# Starship cross-shell prompt. Activated by cookbooks/sheldon/ profile entry.
# This cookbook only installs the binary; prompt activation lives with the
# plugin manager (Sheldon) profile so the prompt + plugin lifecycle stay
# co-located.
#
# Scope: darwin-only for now. linux.rb still uses oh-my-zsh + typewritten
# via cookbooks/dot-zsh platform guard. Extend to ubuntu when linux.rb is
# in scope of the zsh refactor.

return unless node[:platform] == "darwin"

package "starship" do
  not_if { brew_formula?("starship") }
end
