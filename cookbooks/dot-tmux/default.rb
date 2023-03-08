git_clone ".tmux" do
  cwd node[:setup][:root]
  uri "https://github.com/gpakosz/.tmux.git"
end

link "#{ENV["HOME"]}/.tmux.conf" do
  to "#{node[:setup][:root]}/.tmux/.tmux.conf"
  not_if { File.exist?("#{ENV["HOME"]}/.tmux.conf") }
end

remote_file "#{ENV["HOME"]}/.tmux.conf.local" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode '755'
  source 'files/.tmux.conf.local'
  not_if { File.exist?("#{ENV["HOME"]}/.tmux.conf.local") }
end

execute "git pull" do
  cwd "#{node[:setup][:root]}/.tmux"
end
