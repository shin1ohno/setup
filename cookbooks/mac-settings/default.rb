return if node[:platform] != "darwin"

remote_file "#{node[:setup][:root]}/mac-setup.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode '755'
  source 'files/macos'
end

