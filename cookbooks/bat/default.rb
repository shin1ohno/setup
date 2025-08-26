include_cookbook "mise"

# Install bat using mise
execute "$HOME/.local/bin/mise install bat@latest" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list bat | grep -q 'bat'"
end

# Set bat as globally available
execute "$HOME/.local/bin/mise use --global bat@latest" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list bat | grep -q '\\* '"
end

directory "#{ENV["HOME"]}/.config/bat" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

remote_file "#{ENV["HOME"]}/.config/bat/config" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
  source "files/config"
end
