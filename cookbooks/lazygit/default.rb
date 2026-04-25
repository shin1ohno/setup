# frozen_string_literal: true

include_cookbook "mise"

mise_tool "lazygit"

if node[:platform] == "darwin"
  path = "#{node[:setup][:home]}/Library/Application Support/lazygit"
  package "lazygit" do
    action :remove
    only_if { brew_formula?("lazygit") }
  end
else
  path = "#{node[:setup][:home]}/.config/lazygit/"
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
