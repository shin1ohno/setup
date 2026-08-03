# frozen_string_literal: true
#
# git (macOS): brew for the git binaries, mise for gh, plus the removal of two
# formulae this cookbook used to install itself. The OS-independent half — the
# ~/.gitconfig render and the `git config` guards that follow it — is
# common.rb, included LAST so it converges after gh exists.
#
# roles/foundation orders homebrew before this cookbook for the `package`
# resources below; mise is pulled in here rather than by the role because it is
# dependency-free and gh is the only thing that needs it.

package "git"
package "git-lfs"
package "git-filter-repo"

include_cookbook "mise"
mise_tool "gh"

package "gh" do
  action :remove
  only_if { brew_formula?("gh") }
end

# git-ai-commit (takai/tap) removed — drop the formula and the tap.
package "git-ai-commit" do
  action :remove
  only_if { brew_formula?("git-ai-commit") }
end
execute "brew untap takai/tap" do
  only_if { brew_tap?("takai/tap") }
end

include_recipe "common"
