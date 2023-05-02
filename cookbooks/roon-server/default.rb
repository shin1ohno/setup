# frozen_string_literal: true

case node[:platform]
when "darwin"
  directory "#{node[:setup][:root]}/roon" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
  end

  dmg_path = "#{node[:setup][:root]}/roon/RoonServer.dmg"
  pkg_path = "/Volumes/RoonServer/RoonServer.app"
  applicatin_path = "/Applications/RoonServer.app"

  execute "curl --silent --fail https://download.roonlabs.net/builds/earlyaccess/RoonServer.dmg -o #{dmg_path.shellescape}" do
    not_if { File.exist?(dmg_path) }
  end

  execute "sudo -p 'Enter your password to mount Roon Server image: ' hdiutil attach #{dmg_path.shellescape}" do
    not_if { FileTest.directory?(applicatin_path) }
  end

  execute "sudo -p 'Enter your password to install Roon Server: ' cp -rp #{pkg_path} #{applicatin_path} && sudo hdiutil unmount /Volumes/RoonServer" do
    only_if { FileTest.directory?(pkg_path) && !FileTest.directory?(applicatin_path) }
  end

  remote_file "#{node[:setup][:root]}/roon/com.roon.server.plist" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    source "files/com.roon.server.plist"
    not_if { File.exist?("/Library/LaunchDaemons/com.roon.server.plist") }
  end

  execute "sudo cp -rp #{node[:setup][:root]}/roon/com.roon.server.plist /Library/LaunchDaemons/com.roon.server.plist" do
    not_if { FileTest.exist?("/Library/LaunchDaemons/com.roon.server.plist") }
  end
end
