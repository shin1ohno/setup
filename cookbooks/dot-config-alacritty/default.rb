directory "#{ENV["HOME"]}/.config/alacritty" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode '755'
  action :create
end

remote_file "#{ENV["HOME"]}/.config/alacritty/alacritty.yml" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode '755'
  source 'files/alacritty.yml'
end

