# frozen_string_literal: true

include_cookbook "volta"

node[:nodejs][:versions].each do |node_version|
  execute "$HOME/.volta/bin/volta install node@#{node_version}" do
    not_if "$HOME/.volta/bin/volta list --format plain node | grep -q \"node@#{node_version}\""
  end
end

execute "$HOME/.volta/bin/volta install yarn" do
  not_if "test -e \"$HOME/.volta/bin/yarn\""
end

execute "$HOME/.volta/bin/npm upgrade -g" do
  cwd ENV["HOME"]
end

include_cookbook "pm2"
include_cookbook "typescript"
include_cookbook "mcp-hub"
