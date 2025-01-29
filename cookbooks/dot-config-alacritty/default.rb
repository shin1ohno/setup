# frozen_string_literal: true

directory "#{ENV["HOME"]}/.config/alacritty" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

remote_file "#{ENV["HOME"]}/.config/alacritty/alacritty.toml" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/alacritty.toml"
end
