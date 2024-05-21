package "samba" do
  user "root"
end

remote_file "/etc/samba/smb.conf" do
  source "files/smb.conf"
  owner "root"
  group "root"
  mode "0644"
  user "root"
  not_if "test -e /etc/samba/smb.conf"
end

execute "service smbd restart" do
  user "root"
end
