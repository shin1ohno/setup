#!/bin/bash
# Generate claude_desktop_config.json from servers.yml
# Usage: generate_config.sh <servers.yml> <output.json>

set -euo pipefail
# Restrict perms on the temp output file we write (holds plaintext MCP API keys).
umask 077

YAML_FILE="$1"
OUTPUT_FILE="$2"
HOME_DIR="${HOME}"

# Default AWS region for SSM
AWS_REGION="${AWS_REGION:-ap-northeast-1}"

# Helper function to fetch SSM parameter.
# Thin wrapper: no error swallowing, no literal fallback string. A failed fetch
# propagates its non-zero exit to the call site, which fails loud (no poisoned
# config written). Empty/None rejection is also handled at the call site.
fetch_ssm() {
  local param_path="$1"
  aws ssm get-parameter --name "${param_path}" --with-decryption --query "Parameter.Value" --output text --region "${AWS_REGION}"
}

# Convert YAML to JSON
json_config=$(yq -o json "$YAML_FILE")

# Build the mcpServers object
mcp_servers="{}"

# Get list of server names
server_names=$(echo "$json_config" | jq -r '.mcp_servers | keys[]')

for name in $server_names; do
  server=$(echo "$json_config" | jq -r ".mcp_servers[\"$name\"]")

  # Check platform restriction
  platforms=$(echo "$server" | jq -r '.platforms // empty')
  if [ -n "$platforms" ]; then
    current_platform="darwin"  # This script is only run on macOS
    if ! echo "$platforms" | jq -e "index(\"$current_platform\")" > /dev/null 2>&1; then
      continue
    fi
  fi

  server_type=$(echo "$server" | jq -r '.type // "stdio"')

  # Claude Desktop's claude_desktop_config.json only accepts stdio MCP
  # servers (command + args + env). HTTP/SSE entries are silently skipped
  # by Claude Desktop with "not valid MCP server settings".
  #
  # Default for HTTP servers: skip (configure them as account-level Custom
  # Connectors in the app instead). EXCEPTION: a server marked
  # `desktop: mcp-remote` in servers.yml is bridged into the Desktop config as
  # a local stdio entry via `npx -y mcp-remote <url>` (the cognee / roon
  # pattern), making it usable in Desktop Chat WITHOUT an account connector.
  # Such bridged servers are Desktop-Chat-only — NOT visible in Cowork /
  # claude.ai, which only see account-synced Custom Connectors.
  if [ "$server_type" = "http" ]; then
    desktop_mode=$(echo "$server" | jq -r '.desktop // empty')
    if [ "$desktop_mode" = "mcp-remote" ]; then
      url=$(echo "$server" | jq -r '.url' | sed "s|\${HOME}|${HOME_DIR}|g")
      bridge_config=$(jq -n --arg url "$url" '{command: "npx", args: ["-y", "mcp-remote", $url]}')
      mcp_servers=$(echo "$mcp_servers" | jq --arg name "$name" --argjson config "$bridge_config" '. + {($name): $config}')
    fi
    continue
  fi

  # STDIO server
  command=$(echo "$server" | jq -r '.command' | sed "s|\${HOME}|${HOME_DIR}|g")

  # Build args array
  args=$(echo "$server" | jq -r '.args // []' | jq 'map(gsub("\\${HOME}"; env.HOME))')

  # Build env object with SSM resolution
  env_obj="{}"
  if echo "$server" | jq -e '.env' > /dev/null 2>&1; then
    env_keys=$(echo "$server" | jq -r '.env | keys[]')
    for key in $env_keys; do
      value=$(echo "$server" | jq -r ".env[\"$key\"]")

      # Check if value is an SSM reference
      if echo "$server" | jq -e ".env[\"$key\"].ssm" > /dev/null 2>&1; then
        ssm_path=$(echo "$server" | jq -r ".env[\"$key\"].ssm")
        value=$(fetch_ssm "$ssm_path") || { echo "ERROR: SSM fetch failed for $ssm_path" >&2; exit 1; }
        if [ -z "$value" ] || [ "$value" = "None" ]; then
          echo "ERROR: empty SSM value for $ssm_path" >&2
          exit 1
        fi
      else
        # Expand ${HOME}
        value=$(echo "$value" | sed "s|\${HOME}|${HOME_DIR}|g")
      fi

      env_obj=$(echo "$env_obj" | jq --arg k "$key" --arg v "$value" '. + {($k): $v}')
    done
  fi

  # Build server config
  server_config=$(jq -n --arg cmd "$command" '{command: $cmd}')

  if [ "$(echo "$args" | jq 'length')" -gt 0 ]; then
    server_config=$(echo "$server_config" | jq --argjson args "$args" '. + {args: $args}')
  fi

  if [ "$env_obj" != "{}" ]; then
    server_config=$(echo "$server_config" | jq --argjson env "$env_obj" '. + {env: $env}')
  fi

  mcp_servers=$(echo "$mcp_servers" | jq --arg name "$name" --argjson config "$server_config" '. + {($name): $config}')
done

# Build final config
final_config=$(jq -n \
  --argjson servers "$mcp_servers" \
  '{
    mcpServers: $servers,
    isDxtAutoUpdatesEnabled: true,
    preferences: {
      menuBarEnabled: false
    }
  }')

echo "$final_config" > "$OUTPUT_FILE"
