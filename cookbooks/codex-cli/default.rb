# frozen_string_literal: true

include_cookbook "mise"

# Install Codex CLI using mise npm backend
execute "$HOME/.local/bin/mise install npm:@openai/codex@latest" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list npm:@openai/codex | grep -q '@openai/codex'"
end

# Set Codex CLI as globally available
execute "$HOME/.local/bin/mise use --global npm:@openai/codex@latest" do
  user node[:setup][:user]
  not_if "$HOME/.local/bin/mise list npm:@openai/codex | grep -q '\\* '"
end

# Ensure ~/.codex directory exists
directory "#{ENV["HOME"]}/.codex" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

# Generate codex config.toml using shell script
# This uses the same servers.yml as mcp cookbook
mcp_yaml_path = File.join(File.dirname(__FILE__), "..", "mcp", "files", "servers.yml")
generator_script = File.join(File.dirname(__FILE__), "files", "generate_config.sh")
output_path = "#{ENV["HOME"]}/.codex/config.toml"

execute "generate codex config.toml" do
  command "bash #{generator_script} #{mcp_yaml_path} #{output_path}"
  user node[:setup][:user]
end

file output_path do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "644"
end
