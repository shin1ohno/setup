# frozen_string_literal: true
#
# samba-server: Samba SMB share for [Media] (read-only).
#
# Used by:
#   - lxc-samba (inside dedicated samba LXC, /mnt/Media bind-mounted ro)
#   - pve-host? (NO — samba is intentionally not on the host; it lives in LXC for CVE rollback granularity per migration plan)
#
# Distinct from existing `cookbooks/samba/default.rb`: that one packs the
# legacy bare-metal `pro` smb.conf assumptions. This one is parametric on
# the bind-mount path (default /mnt/Media) and can run inside an
# unprivileged LXC.

return if node[:platform] == "darwin"

samba_path = node[:samba_server][:share_path] rescue "/mnt/Media"
samba_share = node[:samba_server][:share_name] rescue "Media"

package "samba" do
  user node[:setup][:system_user]
  not_if { run_command("dpkg-query -W -f='${Status}' samba 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
end

staging_conf = "#{node[:setup][:root]}/samba-server/smb.conf"
system_conf  = "/etc/samba/smb.conf"

directory "#{node[:setup][:root]}/samba-server" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

file staging_conf do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "0644"
  content <<~CONF
    [global]
        workgroup = WORKGROUP
        server string = %h server (Samba %v)
        log file = /var/log/samba/log.%m
        max log size = 1000
        logging = file
        panic action = /usr/share/samba/panic-action %d
        server role = standalone server
        obey pam restrictions = yes
        unix password sync = yes
        passwd program = /usr/bin/passwd %u
        passwd chat = *Enter\\snew\\s*\\spassword:* %n\\n *Retype\\snew\\s*\\spassword:* %n\\n *password\\supdated\\ssuccessfully* .
        pam password change = yes
        map to guest = bad user
        usershare allow guests = yes

    [#{samba_share}]
        path = #{samba_path}
        read only = yes
        browsable = yes
        guest ok = yes
  CONF
end

execute "install samba-server config" do
  command "sudo install -m 644 -o root -g root #{staging_conf} #{system_conf}"
  not_if "diff -q #{staging_conf} #{system_conf} 2>/dev/null"
  notifies :run, "execute[restart smbd + nmbd]"
end

execute "enable smbd + nmbd" do
  command "sudo systemctl enable --now smbd.service nmbd.service"
  not_if "systemctl is-enabled smbd.service 2>/dev/null | grep -q '^enabled$' && systemctl is-enabled nmbd.service 2>/dev/null | grep -q '^enabled$'"
end

execute "restart smbd + nmbd" do
  command "sudo systemctl restart smbd.service nmbd.service"
  action :nothing
end
