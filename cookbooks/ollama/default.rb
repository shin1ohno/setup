# frozen_string_literal: true

case node[:platform]
when 'darwin'
  package 'ollama' do
    action :install
    not_if 'which ollama > /dev/null 2>&1'
  end
else # Linux
  remote_file "#{node[:setup][:root]}/ollama-install-linux.sh" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
    source "files/install.sh"
    only_if { node[:platform] != 'darwin' }
  end

  execute "#{node[:setup][:root]}/ollama-install-linux.sh" do
    not_if 'which ollama > /dev/null 2>&1'
  end
end
