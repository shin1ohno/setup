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

mise_tool "@pimzino/claude-code-spec-workflow" do
  backend "npm"
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
