# frozen_string_literal: true
#
# git (Linux): all three binaries ship as apt packages, so this side is pure
# package data. The OS-independent half — the ~/.gitconfig render and the
# `git config` guards that follow it — is common.rb, included LAST so it
# converges after gh exists.
#
# No arch arm: the pre-split catch-all `else` guarded itself with dpkg-query,
# so it only ever worked on Debian/Ubuntu, and no arch host exists in this
# fleet (the call #820 made for zk). install_package raises on an unknown
# platform rather than silently installing nothing.
install_package "git" do
  ubuntu %w(git git-lfs gh)
end

include_recipe "common"
