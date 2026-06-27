#!/bin/bash
# register_claude_code.sh <servers.yml>
#
# Render the MCP servers declared in servers.yml into Claude Code USER scope —
# an independent render of the same single source the Claude Desktop and Codex
# CLI generators read (mirrors the codex-cli idiom: own read of servers.yml +
# own SSM resolution + native rendering). NOT derived from the deployed Desktop
# config.
#
# Rendering (native — Claude Code supports http/sse directly, no mcp-remote bridge):
#   - http/sse server WITH `desktop: mcp-remote`  -> `claude mcp add --transport`
#   - stdio server (platform-matched)             -> `claude mcp add-json` ({command,args,env})
#   - http/sse WITHOUT `desktop:` flag            -> skipped (claude.ai account
#                                                    connector, configured in-app)
#
# Idempotent: skips any server already in `claude mcp list` (any scope), so
# re-runs and the account connectors are left untouched.
#
# bash 3.2 compatible (macOS default): no arrays / mapfile.
set -euo pipefail

YAML_FILE="${1:?usage: register_claude_code.sh <servers.yml>}"
CLAUDE="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
HOME_DIR="${HOME}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
CURRENT_PLATFORM="${PLATFORM:-darwin}"

if [ ! -x "$CLAUDE" ]; then
  echo "register_claude_code: claude CLI not found at $CLAUDE — skipping" >&2
  exit 0
fi

# Detect yq flavor (mirrors mcp/codex generate_config.sh).
yaml_to_json() {
  if yq --help 2>&1 | grep -q "jq wrapper"; then
    yq '.' "$1"          # Python yq (kislyuk/yq)
  else
    yq -o json "$1"      # Go yq (mikefarah/yq)
  fi
}

fetch_ssm() {
  aws ssm get-parameter --name "$1" --with-decryption \
    --query "Parameter.Value" --output text --region "${AWS_REGION}"
}

existing="$("$CLAUDE" mcp list 2>/dev/null || true)"
json_config="$(yaml_to_json "$YAML_FILE")"

echo "$json_config" | jq -r '.mcp_servers // {} | keys[]' | while IFS= read -r name; do
  # Already registered at some scope? Match "<name>:" at line start.
  if printf '%s\n' "$existing" | grep -q "^${name}:"; then
    continue
  fi

  server="$(echo "$json_config" | jq -c ".mcp_servers[\"$name\"]")"

  # Platform gate (servers may pin platforms: [darwin]).
  platforms="$(echo "$server" | jq -r '.platforms // empty')"
  if [ -n "$platforms" ]; then
    echo "$platforms" | jq -e --arg p "$CURRENT_PLATFORM" 'index($p)' >/dev/null 2>&1 || continue
  fi

  stype="$(echo "$server" | jq -r '.type // "stdio"')"

  if [ "$stype" = "http" ] || [ "$stype" = "sse" ]; then
    # Only render servers meant for local config; skip account connectors.
    desktop="$(echo "$server" | jq -r '.desktop // empty')"
    [ "$desktop" = "mcp-remote" ] || continue
    url="$(echo "$server" | jq -r '.url')"
    transport="$(echo "$server" | jq -r '.transport // "sse"')"
    echo "register_claude_code: adding '$name' ($transport) to Claude Code user scope"
    "$CLAUDE" mcp add -s user --transport "$transport" "$name" "$url" \
      || echo "register_claude_code: failed to add '$name' (continuing)" >&2
  else
    # stdio: resolve command/args/env (incl. SSM) then register via add-json.
    cmd="$(echo "$server" | jq -r '.command' | sed "s|\${HOME}|${HOME_DIR}|g")"
    args="$(echo "$server" | jq -c '(.args // []) | map(gsub("\\${HOME}"; env.HOME))')"
    env_json='{}'
    if echo "$server" | jq -e '.env' >/dev/null 2>&1; then
      for key in $(echo "$server" | jq -r '.env | keys[]'); do
        if echo "$server" | jq -e ".env[\"$key\"].ssm" >/dev/null 2>&1; then
          val="$(fetch_ssm "$(echo "$server" | jq -r ".env[\"$key\"].ssm")")"
        else
          val="$(echo "$server" | jq -r ".env[\"$key\"]" | sed "s|\${HOME}|${HOME_DIR}|g")"
        fi
        env_json="$(echo "$env_json" | jq --arg k "$key" --arg v "$val" '. + {($k): $v}')"
      done
    fi
    spec="$(jq -nc --arg cmd "$cmd" --argjson args "$args" --argjson env "$env_json" \
      '{command: $cmd}
       + (if ($args | length) > 0 then {args: $args} else {} end)
       + (if ($env  | length) > 0 then {env:  $env}  else {} end)')"
    echo "register_claude_code: adding '$name' (stdio) to Claude Code user scope"
    "$CLAUDE" mcp add-json -s user "$name" "$spec" \
      || echo "register_claude_code: failed to add '$name' (continuing)" >&2
  fi
done
