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
#   - server WITH `account_connector: true`       -> skipped (a claude.ai
#                                                    account connector already
#                                                    synced into Claude Code as
#                                                    "claude.ai <name>"; a
#                                                    user-scope add would be a
#                                                    "Needs authentication" dup)
#   - http/sse server (not an account connector)  -> `claude mcp add --transport`
#   - stdio server (platform-matched)             -> `claude mcp add-json` ({command,args,env})
#
# NOTE: `desktop: mcp-remote` is an INDEPENDENT axis (it bridges the server into
# Claude *Desktop*, which cannot use account connectors). It does NOT decide
# Claude Code registration — an earlier version keyed off it and produced
# duplicate user-scope entries for every Desktop-bridged account connector.
#
# Idempotent, two guards: (1) skip any server whose name OR url already appears
# in `claude mcp list` (any scope) — the url guard catches account connectors
# listed under the "claude.ai <name>" label, whose name never matches the yml
# key; (2) skip `account_connector: true` even before it is listed, so a fresh
# machine never adds the dup in the first place.
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

  # claude.ai account connectors sync into Claude Code automatically (listed as
  # "claude.ai <name>"). Never register a user-scope duplicate — it would show
  # "Needs authentication" (no cached OAuth token) and shadow the working one.
  if [ "$(echo "$server" | jq -r '.account_connector // empty')" = "true" ]; then
    echo "register_claude_code: '$name' is a claude.ai account connector — skipping user-scope registration"
    continue
  fi

  # Platform gate (servers may pin platforms: [darwin]).
  platforms="$(echo "$server" | jq -r '.platforms // empty')"
  if [ -n "$platforms" ]; then
    echo "$platforms" | jq -e --arg p "$CURRENT_PLATFORM" 'index($p)' >/dev/null 2>&1 || continue
  fi

  stype="$(echo "$server" | jq -r '.type // "stdio"')"

  if [ "$stype" = "http" ] || [ "$stype" = "sse" ]; then
    url="$(echo "$server" | jq -r '.url')"
    # URL-level dedup: skip when this url is already registered under ANY name.
    # `claude mcp list` prints "<label>: <url> - <status>", so an account
    # connector shown as "claude.ai memory: https://mcp.ohno.be/memory/mcp"
    # is caught here even though its label never matches the yml key "ai-memory".
    if printf '%s\n' "$existing" | grep -qF "$url"; then
      echo "register_claude_code: '$name' url already registered ($url) — skipping"
      continue
    fi
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
