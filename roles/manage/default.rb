# frozen_string_literal: true

repos_file = "#{File.dirname(__FILE__)}/files/repositories.json"
repos = JSON.parse(File.read(repos_file))["repositories"]
l_repos_file = "#{File.dirname(__FILE__)}/files/repositories.local.json"
# `File.exist?` follows symlinks — on macOS this returns true for a link
# pointing into ~/Library/Mobile Documents/ (iCloud Drive) but the actual
# `File.read` then raises Errno::EPERM because mitamae's process lacks
# Full Disk Access. Same shape applies to any sandboxed / protected
# location the user may symlink into. Rescue the read so a missing or
# unreadable local file degrades to "no extra repos" rather than
# aborting the entire role chain (and blocking ssh-keys, mise, tmux,
# etc. that follow it in core/darwin/lxc-dev-workstation).
if File.exist?(l_repos_file)
  begin
    repos.concat(JSON.parse(File.read(l_repos_file))["repositories"])
  rescue Errno::EPERM, Errno::EACCES => e
    MItamae.logger.warn(
      "roles/manage: cannot read #{l_repos_file} (#{e.class.name}: " \
      "#{e.message}) — likely macOS Full Disk Access / sandbox " \
      "restriction on the symlink target. Skipping local repos."
    )
  rescue JSON::ParserError => e
    MItamae.logger.warn(
      "roles/manage: invalid JSON in #{l_repos_file} (#{e.message}). " \
      "Skipping local repos."
    )
  end
end

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
