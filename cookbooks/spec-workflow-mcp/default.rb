# frozen_string_literal: true

# Add spec-workflow-mcp to selected ManagedProjects directories using claude mcp add
# This allows spec-workflow to be loaded only when working in a specific project

managed_projects_dir = "#{ENV['HOME']}/ManagedProjects"
mise_shims = "export PATH=$HOME/.local/share/mise/shims:$PATH"
claude_cmd = "$HOME/.local/share/mise/shims/claude"

# Target projects for spec-workflow-mcp
target_projects = %w[
  sage
  terraform-provider-rtx
  home-monitor
]

target_projects.each do |project_name|
  project_path = "#{managed_projects_dir}/#{project_name}"

  next unless Dir.exist?(project_path)

  # Add spec-workflow MCP server to the project if not already configured
  execute "add spec-workflow mcp to #{project_name}" do
    command "#{mise_shims} && cd #{project_path} && #{claude_cmd} mcp add --scope project spec-workflow -- npx -y @pimzino/spec-workflow-mcp@latest #{project_path}"
    user node[:setup][:user]
    not_if "#{mise_shims} && cd #{project_path} && #{claude_cmd} mcp list 2>/dev/null | grep -q spec-workflow"
  end
end
