# frozen_string_literal: true

if node[:platform] == "darwin"
  package "git"
  package "git-lfs"
  package "gh"
else
  package "git" do
    user node[:setup][:user]
  end
  package "git-lfs" do
    user node[:setup][:user]
  end
  package "gh" do
    user node[:setup][:user]
  end
end

remote_file "#{ENV["HOME"]}/.gitconfig" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/gitconfig"
end
