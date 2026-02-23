include_cookbook "mise"

mise_tool "bat"

directory "#{node[:setup][:home]}/.config/bat" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

remote_file "#{node[:setup][:home]}/.config/bat/config" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  source "files/config"
end
