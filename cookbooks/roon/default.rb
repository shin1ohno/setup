# frozen_string_literal: true

case node[:platform]
when "darwin"
  directory "#{node[:setup][:root]}/roon" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
  end

  dmg_path = "#{node[:setup][:root]}/roon/Roon.dmg"
  pkg_path = "/Volumes/Roon/Roon.app"
  applicatin_path = "/Applications/Roon.app"

  execute "curl --silent --fail https://download.roonlabs.net/builds/earlyaccess/Roon.dmg -o #{dmg_path.shellescape}" do
    not_if { File.exist?(dmg_path) }
  end

  execute "sudo -p 'Enter your password to mount Roon image: ' hdiutil attach #{dmg_path.shellescape}" do
    not_if { FileTest.directory?(applicatin_path) }
  end

  execute "sudo -p 'Enter your password to install Roon: ' cp -rp #{pkg_path} #{applicatin_path} && sudo hdiutil unmount /Volumes/Roon" do
    only_if { FileTest.directory?(pkg_path) && !FileTest.directory?(applicatin_path) }
  end
end
