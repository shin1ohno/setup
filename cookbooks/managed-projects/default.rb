# frozen_string_literal: true

directory node[:managed_projects][:root] do
  owner node[:managed_projects][:user]
  group node[:managed_projects][:group]
  mode '755'
  action :create
end

node[:managed_projects][:repos].each do |repo|
  execute "git clone #{repo[:uri]}" do
    cwd node[:managed_projects][:root]
    user node[:managed_projects][:user]
    not_if "test -e #{node[:managed_projects][:root]}/#{repo[:name]}"
  end
end
