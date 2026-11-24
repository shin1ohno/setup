#!/bin/bash
# Hermetic scenarios for cookbooks/antigravity-cli/files/generate_mcp_config.sh.
# Runs the PRODUCTION generator unmodified against fixture servers.yml files and
# fixture existing configs in a temp dir. Needs yq and jq on PATH; no network.
#
# What this protects: the deployed ~/.gemini/config/mcp_config.json is shared
# with agy's own /mcp edits. The render must map each servers.yml transport onto
# one agy accepts (no SSE), keep servers agy added, drop servers servers.yml no
# longer lists, never read SSM (it has no auth gate), and be byte-stable so the
# recipe's cmp leaves the file alone.
#
# Positive controls: a mutant whose platform skip is removed MUST write a pinned
# server, and a mutant that ignores the previous managed names MUST keep a
# removed server. If either does not, the matching scenario cannot tell a
# working check from a missing one, and the run FAILS.
#
# Exit 0 when every assertion passes. One PASS/FAIL line per assertion.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../files/generate_mcp_config.sh"

T=$(mktemp -d "${TMPDIR:-/tmp}/agy-mcp-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
# Pin the real yq/jq before HOME moves: a mise shim reads its trust state from
# HOME and fails under the fixture HOME.
mkdir -p "$T/bin" "$T/home"
for tool in yq jq; do
  real=$(mise which "$tool" 2>/dev/null || command -v "$tool") || { echo "FAIL  $tool not found"; exit 1; }
  ln -s "$real" "$T/bin/$tool"
done
export PATH="$T/bin:$PATH"
export HOME="$T/home"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS  $*"; }
bad() { fail=$((fail+1)); echo "FAIL  $*"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }
q() { jq -c "$1" "$OUT" 2>/dev/null; }

YAML="$T/servers.yml"
cat > "$YAML" <<'EOF'
mcp_servers:
  pinned-stdio:
    command: "${HOME}/bin/pinned"
    platforms:
      - darwin
    env:
      SECRET:
        ssm: "/mcp/pinned-key"
  streamable:
    type: http
    transport: http
    url: "https://example.test/memory/mcp"
  legacy-sse:
    type: http
    transport: sse
    url: "https://example.test/roon/sse"
  no-transport:
    type: http
    url: "https://example.test/default/sse"
  local-stdio:
    command: "${HOME}/bin/tool"
    args: ["--root", "${HOME}/data"]
    env:
      TOOL_HOME: "${HOME}/.tool"
EOF

OUT="$T/out.json"
EXISTING="$T/existing.json"
NAMES="$T/managed-names.json"
NO_FILE="$T/absent.json"
# run <servers.yml> <existing> <names> [script]
run() {
  rm -f "$OUT" "$OUT.managed-names"
  bash "${4:-$SCRIPT}" "$1" "$2" "$3" "$OUT" > "$T/stdout" 2> "$T/stderr"; echo $?
}

echo "== S1 fresh render maps every transport onto one agy accepts"
rc=$(run "$YAML" "$NO_FILE" "$NO_FILE")
assert_eq "S1 exit 0" 0 "$rc"
assert_eq "S1 server set (pinned skipped)" '["legacy-sse","local-stdio","no-transport","streamable"]' "$(q '.mcpServers|keys')"
assert_eq "S1 transport http -> serverUrl" '{"serverUrl":"https://example.test/memory/mcp"}' "$(q '.mcpServers.streamable')"
assert_eq "S1 transport sse -> mcp-remote bridge" '{"command":"npx","args":["-y","mcp-remote","https://example.test/roon/sse"]}' "$(q '.mcpServers["legacy-sse"]')"
assert_eq "S1 missing transport defaults to sse" '"mcp-remote"' "$(q '.mcpServers["no-transport"].args[1]')"
assert_eq "S1 stdio command has HOME expanded" "\"$HOME/bin/tool\"" "$(q '.mcpServers["local-stdio"].command')"
assert_eq "S1 stdio args have HOME expanded" "[\"--root\",\"$HOME/data\"]" "$(q '.mcpServers["local-stdio"].args')"
assert_eq "S1 stdio env has HOME expanded" "{\"TOOL_HOME\":\"$HOME/.tool\"}" "$(q '.mcpServers["local-stdio"].env')"
assert_eq "S1 no SSE, httpUrl or transport key anywhere" 0 "$(jq '[.. | objects | select(has("url") or has("httpUrl") or has("transport"))] | length' "$OUT")"
assert_eq "S1 managed names recorded" '["streamable","legacy-sse","no-transport","local-stdio"]' "$(jq -c . "$OUT.managed-names" 2>/dev/null)"

echo "== S2 a second run over its own output is byte-identical"
cp "$OUT" "$T/first.json"
cp "$OUT" "$EXISTING"
cp "$OUT.managed-names" "$NAMES"
rc=$(run "$YAML" "$EXISTING" "$NAMES")
assert_eq "S2 exit 0" 0 "$rc"
if cmp -s "$T/first.json" "$OUT"; then ok "S2 output unchanged"; else bad "S2 output changed on re-run"; fi

echo "== S3 servers and keys agy wrote survive; a stale managed entry is overwritten"
cat > "$EXISTING" <<'EOF'
{
  "someSetting": {"keep": true},
  "mcpServers": {
    "user-added": {"serverUrl": "https://user.test/mcp"},
    "streamable": {"serverUrl": "https://stale.test/old"}
  }
}
EOF
rc=$(run "$YAML" "$EXISTING" "$NAMES")
assert_eq "S3 exit 0" 0 "$rc"
assert_eq "S3 user-added server kept" '{"serverUrl":"https://user.test/mcp"}' "$(q '.mcpServers["user-added"]')"
assert_eq "S3 managed entry wins on a name clash" '"https://example.test/memory/mcp"' "$(q '.mcpServers.streamable.serverUrl')"
assert_eq "S3 other top-level keys kept" '{"keep":true}' "$(q '.someSetting')"

echo "== S4 a server servers.yml no longer lists is dropped; one agy added is not"
cat > "$EXISTING" <<'EOF'
{"mcpServers": {"user-added": {"serverUrl": "https://user.test/mcp"}, "retired": {"serverUrl": "https://retired.test/mcp"}}}
EOF
printf '["streamable","retired"]\n' > "$NAMES"
rc=$(run "$YAML" "$EXISTING" "$NAMES")
assert_eq "S4 exit 0" 0 "$rc"
assert_eq "S4 previously managed, now unlisted server dropped" 'false' "$(q '.mcpServers | has("retired")')"
assert_eq "S4 server agy added kept" 'true' "$(q '.mcpServers | has("user-added")')"
printf 'garbage' > "$NAMES"
rc=$(run "$YAML" "$EXISTING" "$NAMES")
assert_eq "S4 unreadable names file treated as empty (exit 0)" 0 "$rc"
assert_eq "S4 unreadable names file drops nothing" 'true' "$(q '.mcpServers | has("retired")')"

echo "== S5 an existing file that is not a JSON object is copied aside, then replaced"
printf 'not json {' > "$EXISTING"
rc=$(run "$YAML" "$EXISTING" "$NO_FILE")
assert_eq "S5 exit 0" 0 "$rc"
assert_eq "S5 managed servers written" 4 "$(q '.mcpServers|length')"
assert_eq "S5 backup holds the old bytes" 'not json {' "$(cat "$EXISTING".invalid-* 2>/dev/null)"
if grep -q '^WARN:' "$T/stderr"; then ok "S5 WARN on stderr"; else bad "S5 no WARN on stderr"; fi

echo "== S6 an unpinned server with ssm: aborts instead of reading SSM"
SSM_YAML="$T/ssm.yml"
cat > "$SSM_YAML" <<'EOF'
mcp_servers:
  leaky:
    command: "/bin/leaky"
    env:
      KEY:
        ssm: "/mcp/leaky-key"
EOF
rc=$(run "$SSM_YAML" "$NO_FILE" "$NO_FILE")
if [[ "$rc" -ne 0 ]]; then ok "S6 non-zero exit ($rc)"; else bad "S6 exit 0 for an unpinned ssm: server"; fi
if grep -q 'leaky uses ssm:' "$T/stderr"; then ok "S6 error names the server"; else bad "S6 error does not name the server: $(cat "$T/stderr")"; fi
if [[ -s "$OUT" ]]; then bad "S6 output written despite the error"; else ok "S6 no output written"; fi

echo "== S7 the real servers.yml renders and leaves out the darwin-pinned server"
rc=$(run "$HERE/../../mcp/files/servers.yml" "$NO_FILE" "$NO_FILE")
assert_eq "S7 exit 0" 0 "$rc"
assert_eq "S7 obsidian-mcp-tools absent" 'false' "$(q '.mcpServers | has("obsidian-mcp-tools")')"
assert_eq "S7 no ssm reference in output" 0 "$(jq '[.. | objects | select(has("ssm"))] | length' "$OUT")"

echo "== C1 positive control: with the platform skip removed, a pinned server is written"
PINNED_YAML="$T/pinned.yml"
cat > "$PINNED_YAML" <<'EOF'
mcp_servers:
  pinned-plain:
    command: "/bin/pinned"
    platforms:
      - darwin
EOF
MUT="$T/mutant-no-platform-skip.sh"
sed 's/| with_entries(select(.value.platforms == null))/| ./' "$SCRIPT" > "$MUT"
if cmp -s "$MUT" "$SCRIPT"; then
  bad "C1 the mutant is identical to the script (the sed no longer matches the platform skip)"
else
  run "$PINNED_YAML" "$NO_FILE" "$NO_FILE" "$MUT" > /dev/null
  if [[ "$(q '.mcpServers | has("pinned-plain")')" == "true" ]]; then
    ok "C1 the pinned-server scenarios detect a missing platform skip"
  else
    bad "C1 the pinned-server scenarios cannot detect a missing platform skip"
  fi
fi

echo "== C2 positive control: ignoring the previous managed names keeps a removed server"
MUT2="$T/mutant-no-previous.sh"
sed 's/^previous=.\[\].$/previous="[]"; MANAGED_NAMES_FILE=\/nonexistent/' "$SCRIPT" > "$MUT2"
if cmp -s "$MUT2" "$SCRIPT"; then
  bad "C2 the mutant is identical to the script (the sed no longer matches previous='[]')"
else
  printf '{"mcpServers": {"retired": {"serverUrl": "https://retired.test/mcp"}}}\n' > "$EXISTING"
  printf '["retired"]\n' > "$NAMES"
  run "$YAML" "$EXISTING" "$NAMES" "$MUT2" > /dev/null
  if [[ "$(q '.mcpServers | has("retired")')" == "true" ]]; then
    ok "C2 the removal scenario detects ignored managed names"
  else
    bad "C2 the removal scenario cannot detect ignored managed names"
  fi
fi

echo
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
