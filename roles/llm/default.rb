# frozen_string_literal: true

# LLM (Large Language Models) role
# This role includes all LLM-related tools and configurations

# Include only essential configurations and dependencies for LLM tools
# Rather than including the entire base role

# System essentials
include_cookbook "git"
include_cookbook "ssh"

# Node.js ecosystem (required for Claude Code)
include_cookbook "volta"
include_cookbook "nodejs"

# Python ecosystem (required for various LLM utilities)
include_cookbook "uv"
include_cookbook "python"

# Package managers and tool version managers
include_cookbook "mise"

# LLM specific tools
include_cookbook "mcp-hub"
include_cookbook "claude-code"

# Add any LLM-specific configurations below
