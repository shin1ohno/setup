package "samba" do
  user node[:setup][:system_user]
end

remote_file "/etc/samba/smb.conf" do
  user node[:setup][:system_user]
  source "files/smb.conf"
  owner node[:setup][:system_user]
  group node[:setup][:system_group]
  mode "0644"
  not_if "test -e /etc/samba/smb.conf"
end

execute "service smbd restart" do
  user node[:setup][:system_user]
end
