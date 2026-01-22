# frozen_string_literal: true

if node[:platform] == "darwin"
  package "git"
  package "git-lfs"
  package "gh"
  package "git-filter-repo"

  execute "brew tap takai/tap" do
    not_if "brew tap | grep -q takai/tap"
  end

  package "git-ai-commit"
else
  package "git" do
    user node[:setup][:system_user]
  end
  package "git-lfs" do
    user node[:setup][:system_user]
  end
  package "gh" do
    user node[:setup][:system_user]
  end
end

remote_file "#{ENV["HOME"]}/.gitconfig" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/gitconfig"
end
