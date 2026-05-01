# frozen_string_literal: true

if node[:platform] == "darwin"
  remote_file "#{node[:setup][:root]}/roon/com.roon.server.plist" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    source "files/com.roon.server.plist"
  end

  execute "copy roon launch daemon" do
    user node[:setup][:system_user]
    command "cp #{node[:setup][:root]}/roon/com.roon.server.plist /Library/LaunchDaemons/com.roon.server.plist"
    not_if "test -f /Library/LaunchDaemons/com.roon.server.plist"
  end

  execute "set roon launch daemon ownership" do
    user node[:setup][:system_user]
    command "chown #{node[:setup][:system_user]}:#{node[:setup][:system_group]} /Library/LaunchDaemons/com.roon.server.plist"
    only_if "test -f /Library/LaunchDaemons/com.roon.server.plist"
  end 
else
  %w(curl ffmpeg cifs-utils).each do |pkg|
    package pkg do
      user node[:setup][:system_user]
      not_if { run_command("dpkg-query -W -f='${Status}' #{pkg} 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
    end
  end

  directory "#{node[:setup][:root]}/roon-server" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
  end

  script_path = "#{node[:setup][:root]}/roon-server/linuxx64.sh"

  remote_file script_path do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    source "files/roonserver-installer-linuxx64.sh"
  end

  execute script_path do
    user node[:setup][:system_user]
    not_if "test -e /opt/RoonServer"
  end

  staging_unit = "#{node[:setup][:root]}/roon-server/roonserver.service"
  system_unit = "/etc/systemd/system/roonserver.service"

  file staging_unit do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    content <<~SERVICE
      [Unit]
      Description=RoonServer
      After=network-online.target

      [Service]
      Type=simple
      User=root
      Environment=ROON_DATAROOT=/var/roon
      Environment=ROON_ID_DIR=/var/roon
      ExecStart=/opt/RoonServer/start.sh
      Restart=always
      RestartSec=10
      LimitNOFILE=65536
      Nice=-15
      MemoryHigh=3G
      MemoryMax=4G

      [Install]
      WantedBy=multi-user.target
    SERVICE
  end

  execute "install roonserver systemd unit" do
    command "sudo cp #{staging_unit} #{system_unit} && sudo chmod 644 #{system_unit}"
    not_if "diff -q #{staging_unit} #{system_unit} 2>/dev/null"
    notifies :run, "execute[roonserver systemctl daemon-reload]"
  end

  execute "roonserver systemctl daemon-reload" do
    command "sudo systemctl daemon-reload && sudo systemctl restart roonserver"
    action :nothing
  end

  execute "enable roonserver" do
    command "sudo systemctl enable roonserver.service"
    not_if "systemctl is-enabled roonserver.service"
  end
end
