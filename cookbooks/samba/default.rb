package "samba" do
  user node[:setup][:user]
end

remote_file "/etc/samba/smb.conf" do
  source "files/smb.conf"
  owner "root"
  group "root"
  mode "0644"
  user node[:setup][:user]
  not_if "test -e /etc/samba/smb.conf"
end

execute "service smbd restart" do
  user node[:setup][:user]
end
