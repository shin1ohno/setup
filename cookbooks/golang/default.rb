# frozen_string_literal: true

if node[:platform] == "ubuntu"
  %w(curl git mercurial make binutils bison gcc build-essential golang
  ).each do |pkg|
    package pkg do
      user "root"
    end
  end
end

remote_file "#{node[:setup][:root]}/gvm-install.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/gvm-installer"
end

execute "GVM_NO_UPDATE_PROFILE=1 #{node[:setup][:root]}/gvm-install.sh" do
  not_if "test -d #{ENV['HOME']}/.gvm"
end

go_versions = node[:go][:versions]
go_default_version = go_versions[0]

add_profile "gvm" do
  priority 60 # Make sure this is loaded after nodebrew
  bash_content <<-BASH
  source $HOME/.gvm/scripts/gvm
  BASH
end

go_versions.each do |v|
  execute "install Go version: #{v}" do
    command <<-EOH
    gvm install #{v}
  EOH
    not_if "~/.gvm/bin/gvm list | grep #{v}"
  end
end

execute "Go version: #{go_default_version} as default" do
  #not sure why but we need bash not sh here
  command <<-EOH
    /bin/bash $HOME/.gvm/scripts/env/use #{go_default_version} --default
  EOH
end
