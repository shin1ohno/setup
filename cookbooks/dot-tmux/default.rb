# frozen_string_literal: true

directory "#{ENV["HOME"]}/.config/tmux" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

execute "git init && git remote add origin git@github.com:shin1ohno/tmux.git && git pull --rebase origin main && git push --set-upstream origin main" do
  cwd "#{ENV["HOME"]}/.config/tmux"
  not_if { File.exists? "#{ENV["HOME"]}/.config/tmux/.git" }
end

execute "git pull --rebase origin main" do
  cwd "#{ENV["HOME"]}/.config/tmux"
end
