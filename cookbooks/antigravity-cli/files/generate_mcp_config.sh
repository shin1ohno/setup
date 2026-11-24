#!/bin/bash
# Generate the Antigravity CLI (agy) MCP config from the shared servers.yml.
# Usage: generate_mcp_config.sh <servers.yml> <existing.json> <managed-names.json> <output.json>
#
# <existing.json> is the deployed ~/.gemini/config/mcp_config.json and
# <managed-names.json> the JSON array of server names the previous run managed;
# either may be absent. The output keeps every server and top-level key of the
# existing file, so a server added through agy's /mcp survives, and replaces the
# managed servers wholesale: a managed entry wins on a name clash, and a name the
# previous run managed but servers.yml no longer lists is dropped. The names this
# run managed are written to <output.json>.managed-names for the caller to keep.
#
# agy speaks stdio and Streamable HTTP (serverUrl) only; legacy SSE is not
# supported, so:
#   type http, transport http -> {serverUrl}
#   type http, transport sse  -> stdio bridge `npx -y mcp-remote <url>`
#                                (the bridge Claude Desktop uses for the same servers)
#   stdio                     -> {command, args, env} with ${HOME} expanded
# A missing transport means sse, as in the codex-cli render.
#
# Servers pinned with `platforms:` are skipped on every OS, as codex-cli does,
# so the only ssm: entry (the darwin-pinned obsidian-mcp-tools) is never read.
# This render has no auth gate, so an unpinned server carrying ssm: aborts the
# run instead of fetching a secret.

set -euo pipefail
umask 077

YAML_FILE="$1"
EXISTING_FILE="$2"
MANAGED_NAMES_FILE="$3"
OUTPUT_FILE="$4"

# Python yq (kislyuk/yq) and Go yq (mikefarah/yq) take different arguments.
yaml_to_json() {
  if yq --help 2>&1 | grep -q "jq wrapper"; then
    yq '.' "$1"
  else
    yq -o json "$1"
  fi
}

managed=$(yaml_to_json "$YAML_FILE" | jq --arg home "$HOME" '
  def expand: if type == "string" then gsub("\\$\\{HOME\\}"; $home) else . end;
  (.mcp_servers // {})
  | with_entries(select(.value.platforms == null))
  | with_entries(
      .key as $name
      | if ([.value | .. | objects | select(has("ssm"))] | length) > 0 then
          error("server \($name) uses ssm:, which the Antigravity render cannot resolve (it has no auth gate); pin the server with platforms: or add a gate")
        else . end
      | .value |= (
          if (.type // "stdio") == "http" then
            if .url == null then error("server \($name): type http needs url") else . end
            | if (.transport // "sse") == "sse" then
                {command: "npx", args: ["-y", "mcp-remote", (.url | expand)]}
              else
                {serverUrl: (.url | expand)}
              end
          else
            {command: (.command | expand)}
            + (if ((.args // []) | length) > 0 then {args: (.args | map(expand))} else {} end)
            + (if ((.env // {}) | length) > 0 then {env: (.env | map_values(expand))} else {} end)
          end))
')

existing='{}'
if [ -f "$EXISTING_FILE" ]; then
  if jq -e 'type == "object"' "$EXISTING_FILE" > /dev/null 2>&1; then
    existing=$(cat "$EXISTING_FILE")
  else
    backup="${EXISTING_FILE}.invalid-$(date +%Y%m%d%H%M%S)"
    cp -p "$EXISTING_FILE" "$backup"
    echo "WARN: $EXISTING_FILE is not a JSON object; copied it to $backup and writing the managed servers only" >&2
  fi
fi

previous='[]'
if [ -f "$MANAGED_NAMES_FILE" ] && jq -e 'type == "array" and all(type == "string")' "$MANAGED_NAMES_FILE" > /dev/null 2>&1; then
  previous=$(cat "$MANAGED_NAMES_FILE")
fi

jq -n --argjson existing "$existing" --argjson managed "$managed" --argjson previous "$previous" '
  (if ($existing.mcpServers | type) == "object" then $existing.mcpServers else {} end) as $current
  | (reduce ($previous[] | select(. as $k | $managed | has($k) | not)) as $gone
      ($current; del(.[$gone]))) as $kept
  | $existing + {mcpServers: ($kept + $managed)}
' > "$OUTPUT_FILE"

jq -n --argjson managed "$managed" '$managed | keys_unsorted' > "${OUTPUT_FILE}.managed-names"
