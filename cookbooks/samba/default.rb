package "samba" do
  user node[:setup][:system_user]
  not_if { run_command("dpkg-query -W -f='${Status}' samba 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
end

staging_conf = "#{node[:setup][:root]}/samba/smb.conf"
system_conf = "/etc/samba/smb.conf"

directory "#{node[:setup][:root]}/samba" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

remote_file staging_conf do
  source "files/smb.conf"
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0644"
end

execute "install samba config" do
  command "sudo cp #{staging_conf} #{system_conf} && sudo chmod 644 #{system_conf}"
  not_if "diff -q #{staging_conf} #{system_conf} 2>/dev/null"
  notifies :run, "execute[service smbd restart]"
end

execute "service smbd restart" do
  command "sudo systemctl restart smbd"
  action :nothing
end
