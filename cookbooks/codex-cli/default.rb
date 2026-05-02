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
directory "#{node[:setup][:home]}/.codex" do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

# Create generated directory for temporary files
generated_dir = "#{node[:setup][:root]}/generated"
directory generated_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
  action :create
end

# Generate codex config.toml using shell script
# This uses the same servers.yml as mcp cookbook
mcp_yaml_path = File.join(File.dirname(__FILE__), "..", "mcp", "files", "servers.yml")
generator_script = File.join(File.dirname(__FILE__), "files", "generate_config.sh")
temp_path = "#{generated_dir}/codex_config.toml"
output_path = "#{node[:setup][:home]}/.codex/config.toml"

# generate_config.sh fetches MCP server credentials from SSM. Block here
# until AWS auth is in place — interactive pause + re-check loop.
#
# Generate, install, and clean up in one atomic execute. A previous split
# into separate generate / remote_file / file resources had a compile-vs-
# converge ordering bug: the deploy step gated by Ruby's `if File.exist?(
# temp_path)` evaluated at recipe-load time, before the generate execute
# had run, so the deploy and cleanup resources were never declared on a
# clean run. Folding the three steps into one shell pipeline sidesteps the
# ordering issue entirely.
require_external_auth(
  tool_name: "AWS CLI (for MCP server SSM params)",
  check_command: "aws sts get-caller-identity",
  instructions: "On a fresh machine: aws configure (or aws configure --profile <name> + export AWS_PROFILE=<name>). Then press Enter to retry.",
) do
  execute "generate and deploy codex config.toml" do
    command <<~CMD.strip
      set -euo pipefail
      bash #{generator_script} #{mcp_yaml_path} #{temp_path}
      install -m 644 #{temp_path} #{output_path}
      rm -f #{temp_path}
    CMD
    user node[:setup][:user]
  end
end
