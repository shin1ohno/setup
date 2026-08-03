# frozen_string_literal: true
#
# zk — command-line note manager for the Zettelkasten method.
# https://github.com/zk-org/zk
#
# darwin half: mise's aqua backend. The linux half unpacks the upstream release
# tarball instead (cookbooks/zk/linux.rb) — different resources entirely, hence
# the per-OS split.
include_cookbook "mise"

# zk is not in mise's core registry; use the aqua backend (zk-org/zk).
mise_tool "zk-org/zk" do
  backend "aqua"
end

# Drop the Homebrew formula superseded by the mise-managed binary.
package "zk" do
  action :remove
  only_if { brew_formula?("zk") }
end
