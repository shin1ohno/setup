#!/bin/bash
# Generate codex config.toml from servers.yml
# Usage: generate_config.sh <servers.yml> <output.toml>

set -euo pipefail

YAML_FILE="$1"
OUTPUT_FILE="$2"
HOME_DIR="${HOME}"
MANAGED_PROJECTS_DIR="${HOME_DIR}/ManagedProjects"

# Default AWS region for SSM
AWS_REGION="${AWS_REGION:-ap-northeast-1}"

# Helper function to fetch SSM parameter
fetch_ssm() {
  local param_path="$1"
  aws ssm get-parameter --name "${param_path}" --with-decryption --query "Parameter.Value" --output text --region "${AWS_REGION}" 2>/dev/null || echo "SSM_FETCH_FAILED:${param_path}"
}

# Start building config.toml
{
  # Add trusted projects
  echo "[projects.\"${HOME_DIR}\"]"
  echo 'trust_level = "trusted"'
  echo ""

  if [ -d "$MANAGED_PROJECTS_DIR" ]; then
    for dir in "$MANAGED_PROJECTS_DIR"/*/; do
      if [ -d "$dir" ]; then
        dir="${dir%/}"  # Remove trailing slash
        echo "[projects.\"${dir}\"]"
        echo 'trust_level = "trusted"'
        echo ""
      fi
    done
  fi

  # Convert YAML to JSON and process MCP servers
  json_config=$(yq -o json "$YAML_FILE")
  server_names=$(echo "$json_config" | jq -r '.mcp_servers | keys[]')

  for name in $server_names; do
    server=$(echo "$json_config" | jq -r ".mcp_servers[\"$name\"]")

    # Check platform restriction - skip platform-specific servers for codex
    # (codex runs cross-platform, so we include all non-platform-specific servers)
    platforms=$(echo "$server" | jq -r '.platforms // empty')
    if [ -n "$platforms" ]; then
      # Skip platform-specific servers for now
      continue
    fi

    server_type=$(echo "$server" | jq -r '.type // "stdio"')

    echo "[mcp_servers.${name}]"

    if [ "$server_type" = "http" ]; then
      # HTTP server
      url=$(echo "$server" | jq -r '.url')

      # Check if url is an SSM reference
      if echo "$server" | jq -e '.url.ssm' > /dev/null 2>&1; then
        ssm_path=$(echo "$server" | jq -r '.url.ssm')
        url=$(fetch_ssm "$ssm_path")
      fi

      transport=$(echo "$server" | jq -r '.transport // "sse"')

      echo "type = \"http\""
      echo "url = \"${url}\""
      echo "transport = \"${transport}\""
    else
      # STDIO server
      command=$(echo "$server" | jq -r '.command' | sed "s|\${HOME}|${HOME_DIR}|g")
      echo "command = \"${command}\""

      # Build args array
      args=$(echo "$server" | jq -r '.args // []')
      if [ "$(echo "$args" | jq 'length')" -gt 0 ]; then
        args_formatted=$(echo "$args" | jq -r 'map(gsub("\\${HOME}"; env.HOME)) | @json' | sed 's/","/", "/g')
        echo "args = ${args_formatted}"
      fi

      # Build env section
      if echo "$server" | jq -e '.env' > /dev/null 2>&1; then
        echo ""
        echo "[mcp_servers.${name}.env]"
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

          echo "${key} = \"${value}\""
        done
      fi
    fi
    echo ""
  done
} > "$OUTPUT_FILE"
