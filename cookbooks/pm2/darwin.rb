# frozen_string_literal: true
#
# pm2 (macOS): `pm2 startup launchd` wiring. The two OS-independent halves are
# install.rb (nodejs + the mise npm install) and profile.rb (the lazy
# completion wrapper); this file holds only what launchd needs, between them.

include_recipe "install"

# Pre-create ~/Library/LaunchAgents. pm2 6.0.14's `startup launchd` tries
# to open the plist for writing before running its own `mkdir -p` step,
# which ENOENT-fails on fresh Macs where the directory doesn't yet exist.
directory "#{node[:setup][:home]}/Library/LaunchAgents" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

execute "setup pm2" do
  command "sudo env PATH=$PATH:#{node[:setup][:home]}/.local/share/mise/shims #{node[:setup][:home]}/.local/share/mise/shims/pm2 startup launchd -u $USER --hp #{node[:setup][:home]}"
  not_if "test -f ~/Library/LaunchAgents/pm2.$USER.plist"
end

include_recipe "profile"
