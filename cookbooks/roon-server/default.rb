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
end
