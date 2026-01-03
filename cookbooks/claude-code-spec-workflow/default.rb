# frozen_string_literal: true

# Claude Code Spec Workflow - Structured development workflow automation for Claude Code
# Provides spec-driven development and bug fix workflows with slash commands
# https://github.com/Pimzino/claude-code-spec-workflow

# Ensure mise is installed
include_cookbook "mise"

# Ensure Node.js is installed via mise (provides npm)
include_cookbook "nodejs"

# Ensure Claude Code is installed (dependency)
include_cookbook "claude-code"

# Install Claude Code Spec Workflow globally using mise
execute "install claude-code-spec-workflow via mise" do
  user node[:setup][:user]
  command "$HOME/.local/bin/mise use --global npm:@pimzino/claude-code-spec-workflow@latest"
  not_if "$HOME/.local/bin/mise list | grep -q 'npm:@pimzino/claude-code-spec-workflow'"
end

# Add profile entry for documentation
add_profile "claude-code-spec-workflow" do
  bash_content <<~BASH
    # Claude Code Spec Workflow - Development workflow automation
    # Run 'claude-code-spec-workflow' in a project directory to set up
    # This creates .claude/ directory with commands, templates, and steering docs
  BASH
  fish_content <<~FISH
    # Claude Code Spec Workflow - Development workflow automation
    # Run 'claude-code-spec-workflow' in a project directory to set up
    # This creates .claude/ directory with commands, templates, and steering docs
  FISH
end
