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
end
