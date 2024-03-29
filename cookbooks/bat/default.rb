# frozen_string_literal: true

case node[:platform]
  when "darwin"
    package "bat"
  else
  package "bat" do
    user "root"
  end
end

directory "#{ENV["HOME"]}/.config/bat" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

remote_file "#{ENV["HOME"]}/.config/bat/config" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  source "files/config"
end
