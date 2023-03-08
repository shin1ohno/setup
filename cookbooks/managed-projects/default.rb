# frozen_string_literal: true

directory node[:managed_projects][:root] do
  owner node[:managed_projects][:user]
  group node[:managed_projects][:group]
  mode '755'
  action :create
end

node[:managed_projects][:repos].each do |repo|
  git_clone repo[:name] do
    name repo[:name]
    uri repo[:uri]
    cwd node[:managed_projects][:root]
  end
end
