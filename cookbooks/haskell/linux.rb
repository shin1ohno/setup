# frozen_string_literal: true
#
# haskell, linux half: stack from its official install script, after the
# shared ghcup bootstrap (ghcup.rb). macOS takes stack from mise and cleans up
# the old Homebrew formulae instead (cookbooks/haskell/darwin.rb).
include_recipe "ghcup"

remote_file "#{node[:setup][:root]}/stack-install.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/stack-install.sh"
end

execute "#{node[:setup][:root]}/stack-install.sh" do
  not_if "which stack > /dev/null"
end

include_recipe "profile"
