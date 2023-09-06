# frozen_string_literal: true

remote_file "#{node[:setup][:root]}/gvm-install.sh" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/gvm-installer"
end

execute "GVM_NO_UPDATE_PROFILE=1 #{node[:setup][:root]}/gvm-install.sh" do
  not_if "test -d #{ENV['HOME']}/.gvm"
end

add_profile "gvm" do
  priority 60 # Make sure this is loaded after nodebrew
  bash_content <<-BASH
  source $HOME/.gvm/scripts/gvm
  BASH
end

execute "gvm install go1.19 -B" do
  not_if "test -d $HOME/.gvm/gos/go1.19"
end

execute "gvm use go1.19 --default" do
  not_if "test -e $HOME/.gvm/environments/default"
end
