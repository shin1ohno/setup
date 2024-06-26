remote_file "#{node[:setup][:root]}/rclone-install.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/install.sh"
end

execute "RCLONE_NO_UPDATE_PROFILE=1 #{node[:setup][:root]}/rclone-install.sh" do
  not_if "test -d #{ENV['HOME']}/.rclone"
  user "root"
end

