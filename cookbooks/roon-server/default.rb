# frozen_string_literal: true

case node[:platform]
when "darwin"
  remote_file "#{node[:setup][:root]}/roon/com.roon.server.plist" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    source "files/com.roon.server.plist"
  end

  execute "sudo cp #{node[:setup][:root]}/roon/com.roon.server.plist /Library/LaunchDaemons/com.roon.server.plist"
  execute "sudo chown root:wheel /Library/LaunchDaemons/com.roon.server.plist" 
when "ubuntu"
  %w(curl ffmpeg cifs-utils).each do |pkg| 
    package pkg
  end
 
  directory "#{node[:setup][:root]}/roon" do
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
    user node[:setup][:user]
    not_if "test -e /opt/RoonServer"
  end
end
