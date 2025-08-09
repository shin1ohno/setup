# frozen_string_literal: true

# LLM (Large Language Models) role
# This role includes all LLM-related tools and configurations
# Assumes core and programming roles are already included

# LLM specific tools
include_cookbook "claude-code"
include_cookbook "gemini-cli"
include_cookbook "ollama"
include_cookbook "llama-3-elyza-jp"
include_cookbook "tfmcp"

# Additional Node.js tooling for LLM workflows
# Volta removed - Node.js is now managed by mise via nodejs cookbook
include_cookbook "bun"
include_cookbook "mcp"
include_cookbook "serena"
