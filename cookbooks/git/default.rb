# frozen_string_literal: true

if node[:platform] == "darwin"
  package "git"
  package "git-lfs"
  package "lazygit"
  package "gh"
else
  package "git" do
    user "root"
  end
  package "git-lfs" do
    user "root"
  end
  package "gh" do
    user "root"
  end
end

if node[:platform] == "ubuntu"
  execute "Install Lazygit" do
    code <<-EOF
    LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
curl -Lo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
tar xf lazygit.tar.gz lazygit
sudo install lazygit /usr/local/bin
    EOF
    user root
  end
end

remote_file "#{ENV["HOME"]}/.gitconfig" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/gitconfig"
end
