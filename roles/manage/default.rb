# frozen_string_literal: true

repos_file = "#{File.dirname(__FILE__)}/files/repositories.json"
repos = JSON.parse(File.read(repos_file))["repositories"]
l_repos_file = "#{File.dirname(__FILE__)}/files/repositories.local.json"
repos = repos.concat(JSON.parse(File.read(l_repos_file))["repositories"]) if File.exist?(l_repos_file)

node.reverse_merge!(
  managed_projects: {
    root: "#{node[:setup][:home]}/ManagedProjects",
    user: node[:setup][:user],
    group: node[:setup][:group],
    repos: repos.map { |r| r.keys.map { |k| [k.to_sym, r[k]] } }.map(&:to_h)
  }
)

# Required before managed-projects so `codecommit::*` URIs in
# repositories.json resolve at clone time.
include_cookbook "git-remote-codecommit"

include_cookbook "managed-projects"
