#!/bin/bash
# Generate claude_desktop_config.json from servers.yml
# Usage: generate_config.sh <servers.yml> <output.json>

set -euo pipefail

YAML_FILE="$1"
OUTPUT_FILE="$2"
HOME_DIR="${HOME}"

# Default AWS region for SSM
AWS_REGION="${AWS_REGION:-ap-northeast-1}"

# Helper function to fetch SSM parameter
fetch_ssm() {
  local param_path="$1"
  aws ssm get-parameter --name "${param_path}" --with-decryption --query "Parameter.Value" --output text --region "${AWS_REGION}" 2>/dev/null || echo "SSM_FETCH_FAILED:${param_path}"
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

  if [ "$server_type" = "http" ]; then
    # HTTP server
    url=$(echo "$server" | jq -r '.url')

    # Check if url is an SSM reference
    if echo "$server" | jq -e '.url.ssm' > /dev/null 2>&1; then
      ssm_path=$(echo "$server" | jq -r '.url.ssm')
      url=$(fetch_ssm "$ssm_path")
    fi

    transport=$(echo "$server" | jq -r '.transport // "sse"')

    server_config=$(jq -n \
      --arg url "$url" \
      --arg transport "$transport" \
      '{type: "http", url: $url, transport: $transport}')
  else
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
          value=$(fetch_ssm "$ssm_path")
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
