# frozen_string_literal: true

# server only recipes/cookbooks

directory "#{node[:setup][:home]}/deploy" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end
