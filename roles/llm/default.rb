# frozen_string_literal: true

# LLM (Large Language Models) role
# This role includes all LLM-related tools and configurations
# Assumes core and programming roles are already included

# MCP must be included first to set node[:mcp_servers] for other cookbooks
include_cookbook "mcp"

# LLM specific tools
include_cookbook "claude-code"
include_cookbook "claude-code-spec-workflow"
include_cookbook "gemini-cli"
include_cookbook "codex-cli"  # Uses node[:mcp_servers] from mcp cookbook
include_cookbook "ollama"
include_cookbook "llama-3-elyza-jp"
include_cookbook "tfmcp"

# Additional Node.js tooling for LLM workflows
# Volta removed - Node.js is now managed by mise via nodejs cookbook
include_cookbook "bun"
include_cookbook "notion"
include_cookbook "serena"
include_cookbook "spec-workflow-mcp"
include_cookbook "takt"

# Remove mise shim for claude after all mise operations are done.
# Any `mise use` call regenerates shims for binaries found under
# mise-managed node globals, so this must run last.
file "#{ENV["HOME"]}/.local/share/mise/shims/claude" do
  action :delete
end
