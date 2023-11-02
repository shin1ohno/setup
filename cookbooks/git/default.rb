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
remote_file "#{ENV["HOME"]}/.gitconfig" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/gitconfig"
end
