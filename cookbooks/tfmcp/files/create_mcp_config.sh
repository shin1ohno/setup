#!/bin/bash

# Create Claude Desktop MCP configuration for tfmcp
# This script generates the mcpconfig.json file in the user's home directory

mkdir -p "$HOME/.config/claude"

cat > "$HOME/.config/claude/mcpconfig.json" << EOF
{
  "mcpServers": {
    "tfmcp": {
      "command": "${HOME}/.cargo/bin/tfmcp",
      "args": ["mcp"],
      "env": {
        "HOME": "${HOME}",
        "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${HOME}/.cargo/bin",
        "TERRAFORM_DIR": "${HOME}/terraform",
        "TFMCP_LOG_LEVEL": "info"
      }
    }
  }
}
EOF

echo "Claude Desktop MCP configuration for tfmcp has been created at $HOME/.config/claude/mcpconfig.json"
