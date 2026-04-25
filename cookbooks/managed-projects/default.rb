# frozen_string_literal: true

# Depends on ssh-keys: the private device key must be in place before any
# git@github.com clone can succeed. ssh-keys pauses for AWS auth itself.
# The matching public key is registered to github.com/shin1ohno via
# home-monitor's Terraform `github_user_ssh_key.device[*]`.
include_cookbook "ssh-keys"

directory node[:managed_projects][:root] do
  owner node[:managed_projects][:user]
  group node[:managed_projects][:group]
  mode "755"
  action :create
end

node[:managed_projects][:repos].each do |repo|
  git_clone repo[:name] do
    uri repo[:uri]
    cwd node[:managed_projects][:root]
  end
end
