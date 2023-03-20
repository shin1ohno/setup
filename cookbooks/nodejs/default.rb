# frozen_string_literal: true

include_cookbook "volta"

node_user = ENV["SUDO_USER"] || ENV.fetch("USER")

node_versions = %w(16 17 18 19).map(&:to_s)

node_versions.each do |node_version|
  execute "$HOME/.volta/bin/volta install node@#{node_version}" do
    user node_user
    not_if "$HOME/.volta/bin/volta list --format plain node | grep -q \"node@#{node_version}\""
  end
end

execute "$HOME/.volta/bin/volta install yarn" do
  user node_user
  not_if "test -e \"$HOME/.volta/bin/yarn\""
end

execute "$HOME/.volta/bin/npm upgrade -g" do
  cwd ENV["HOME"]
end

include_cookbook "pm2"
include_cookbook "typescript"
