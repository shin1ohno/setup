remote_file "#{node[:setup][:root]}/tailscale.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/install.sh"
end

execute "#{node[:setup][:root]}/tailscale.sh" do
  not_if "which tailscale"
end

