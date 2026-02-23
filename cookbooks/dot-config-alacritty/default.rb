# frozen_string_literal: true

directory "#{node[:setup][:home]}/.config/alacritty" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

remote_file "#{node[:setup][:home]}/.config/alacritty/alacritty.toml" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/alacritty.toml"
end
