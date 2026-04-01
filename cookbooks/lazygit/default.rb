# # frozen_string_literal: true

if node[:platform] == "darwin"
  path = "#{node[:setup][:home]}/Library/Application Support/lazygit" 
    package "lazygit"
else
  path = "#{node[:setup][:home]}/.config/lazygit/"
  execute "install lazygit via go" do
    command "export PATH=$HOME/.local/share/mise/shims:$PATH && go install github.com/jesseduffield/lazygit@latest"
    not_if "test -x $HOME/.local/share/mise/shims/go && which lazygit"
  end
end

directory path do
  user  node[:setup][:user]
  group node[:setup][:group]
  action :create
  mode "744"
end

remote_file "#{path}/config.yml" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/config.yml"
end
