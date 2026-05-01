# frozen_string_literal: true

if node[:platform] == "darwin"
  package "git"
  package "git-lfs"
  package "git-filter-repo"

  include_cookbook "mise"
  mise_tool "gh"

  package "gh" do
    action :remove
    only_if { brew_formula?("gh") }
  end

  # git-ai-commit (takai/tap) removed — drop the formula and the tap.
  package "git-ai-commit" do
    action :remove
    only_if { brew_formula?("git-ai-commit") }
  end
  execute "brew untap takai/tap" do
    only_if { brew_tap?("takai/tap") }
  end
else
  %w(git git-lfs gh).each do |pkg|
    package pkg do
      user node[:setup][:system_user]
      not_if { run_command("dpkg-query -W -f='${Status}' #{pkg} 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
    end
  end
end

remote_file "#{node[:setup][:home]}/.gitconfig" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  source "files/gitconfig"
end
