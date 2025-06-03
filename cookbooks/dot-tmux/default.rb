# frozen_string_literal: true

directory "#{ENV["HOME"]}/.config/tmux/plugins" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

execute "Initialise tmux config directory" do
  command <<EOF
    git init &&\n
    git remote add origin git@github.com:shin1ohno/tmux.git &&\n
    git pull --rebase origin main &&\n
    git push --set-upstream origin main &&\n 
EOF
  cwd "#{ENV["HOME"]}/.config/tmux"
  not_if { File.exists? "#{ENV["HOME"]}/.config/tmux/.git" }
end

execute "Initialise TPM" do
  command <<EOF
  git clone https://github.com/tmux-plugins/tpm #{ENV["HOME"]}/.config/tmux/plugins/tpm && #{ENV["HOME"]}/.config/tmux/plugins/tpm/bin/install_plugins
EOF
  not_if { File.exists? "#{ENV["HOME"]}/.config/tmux/plugins/tpm"}
end

execute "git pull --rebase origin main" do
  cwd "#{ENV["HOME"]}/.config/tmux"
end
