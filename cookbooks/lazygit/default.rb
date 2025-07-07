# # frozen_string_literal: true

if node[:platform] == "darwin"
  path = "#{ENV["HOME"]}/Library/Application Support/lazygit" 
    package "lazygit"
else
  execute "go install github.com/jesseduffield/lazygit@latest" do
    path = "#{ENV["HOME"]}/.config/lazygit/"
    not_if "which lazygit"
  end
end

directory path do
  user  node[:setup][:user]
  group node[:setup][:group]
  action :create
  mode "744"
end

remote_file "#{path}/config.yml" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/config.yml"
end
