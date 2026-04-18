# frozen_string_literal: true

return if node[:platform] != "darwin"

directory "#{node[:setup][:home]}/.config/ghostty" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

remote_file "#{node[:setup][:home]}/.config/ghostty/config" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/config"
end
