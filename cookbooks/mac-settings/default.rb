return if node[:platform] != "darwin"

remote_file "#{node[:setup][:root]}/mac-setup.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode '755'
  source 'files/macos'
end

execute "echo | env HAVE_SUDO_ACCESS=0 #{node[:setup][:root]}/mac-setup.sh" do
  not_if "test -f #{node[:homebrew][:prefix]}/bin/brew" #only initial setup
end


