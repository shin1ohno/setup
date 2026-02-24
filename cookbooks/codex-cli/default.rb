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

# Generate config to temporary location in setup root
execute "generate codex config.toml" do
  command "bash #{generator_script} #{mcp_yaml_path} #{temp_path}"
  user node[:setup][:user]
end

# Deploy and clean up only when the generated file exists.
# During --dry-run the execute above is a no-op so temp_path won't exist;
# during a real run, a generate failure halts execution before reaching here.
if File.exist?(temp_path)
  remote_file output_path do
    source temp_path
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
  end

  # Clean up temporary file (contains sensitive SSM values)
  file temp_path do
    action :delete
  end
end
