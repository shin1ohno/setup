#!/usr/bin/env bash

# Black-box tests for hooks/mcp-health-check.rb — the attention report and the
# ignore list around it.
#
# Every case runs the hook the way Claude Code does (ruby -E UTF-8, as
# settings.json invokes it through ruby-shim) under `env -i` with a throwaway
# HOME, in the hook's fixture mode: MCP_HEALTH_FIXTURE_FILE stands in for
# `claude mcp list`, MCP_HEALTH_CACHE_FILE keeps the cache out of ~/.claude,
# and the ignore list is either the default $HOME/.claude/mcp-health-ignore.txt
# or MCP_HEALTH_IGNORE_FILE. Both polarities are asserted: with no ignore list
# every NEEDS-AUTH / PENDING / DOWN name is reported (positive control), and
# ignored names disappear from the report while the cache keeps them. A missing
# or unreadable ignore file must behave exactly like no file.
#
# Usage: [RUBY=/path/to/ruby] bash test-mcp-health-check.sh <path-to-mcp-health-check.rb>

set -uo pipefail
HOOK="${1:?path to mcp-health-check.rb}"
HOOK=$(cd "$(dirname "$HOOK")" && pwd)/$(basename "$HOOK")
# Resolve the real interpreter once: a version-manager shim (rbenv / mise) on
# PATH can fail once HOME points at a throwaway directory.
RUBY="${RUBY:-$(ruby -e 'print RbConfig.ruby')}"
[ -x "$RUBY" ] || { echo "FAIL ruby not found"; exit 1; }
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0; n=0

ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s :: %s\n' "$1" "$2"; }

FIXTURE="$ROOT/list.txt"
cat > "$FIXTURE" <<'FIX'
Checking MCP server health…

claude.ai Alpha: https://alpha.example/mcp - ✔ Connected
claude.ai Beta: https://beta.example/mcp - ! Needs authentication
claude.ai Gamma Thing: https://gamma.example/mcp - ! Needs authentication
delta: http://127.0.0.1:1/mcp (HTTP) - ! Needs authentication
epsilon: https://epsilon.example/mcp - ✗ Failed to connect
zeta: https://zeta.example/mcp - ⏸ Pending approval
FIX

# prep: fresh HOME; IGN is the hook's default ignore-list path inside it.
prep() {
  n=$((n+1)); H="$ROOT/h$n"; mkdir -p "$H/.claude"
  CACHE="$H/cache.json"; IGN="$H/.claude/mcp-health-ignore.txt"
}

# go [ignore-file]: run the hook in fixture mode; sets OUT, ERR, RC.
go() {
  local extra=()
  [ $# -ge 1 ] && extra=(MCP_HEALTH_IGNORE_FILE="$1")
  OUT=$(env -i HOME="$H" PATH=/usr/bin:/bin LANG= \
          MCP_HEALTH_FIXTURE_FILE="$FIXTURE" MCP_HEALTH_CACHE_FILE="$CACHE" \
          ${extra[@]+"${extra[@]}"} "$RUBY" -E UTF-8 "$HOOK" 2>"$H/stderr")
  RC=$?
  ERR=$(cat "$H/stderr")
}

clean_json() { # <case>: exit 0, silent stderr, stdout is one JSON object
  [ "$RC" -eq 0 ] && ok "$1 exit 0" || bad "$1 exit 0" "rc=$RC"
  [ -z "$ERR" ] && ok "$1 stderr empty" || bad "$1 stderr empty" "$ERR"
  if printf '%s' "$OUT" | "$RUBY" -rjson -e 'JSON.parse(STDIN.read)' >/dev/null 2>&1; then
    ok "$1 stdout is JSON"
  else
    bad "$1 stdout is JSON" "$OUT"
  fi
}
has()   { case "$OUT" in *"$2"*) ok "$1 reports '$2'" ;; *) bad "$1 reports '$2'" "$OUT" ;; esac; }
hasnt() { case "$OUT" in *"$2"*) bad "$1 drops '$2'" "$OUT" ;; *) ok "$1 drops '$2'" ;; esac; }

# 1. No ignore list: every attention name is reported (positive control).
prep; go; clean_json no-ignore
for name in "claude.ai Beta" "claude.ai Gamma Thing" "delta" "epsilon" "zeta"; do has no-ignore "$name"; done
has no-ignore "NEEDS-AUTH:"; has no-ignore "PENDING approval"; has no-ignore "DOWN (transient)"
hasnt no-ignore "claude.ai Alpha"
BASELINE="$OUT"
[ -n "$BASELINE" ] || { echo "FAIL precondition: baseline report is empty"; exit 1; }

# 2. Default path, mixed content: comment, blank line, different case, padding.
prep; printf '# intentionally disconnected\n\nCLAUDE.AI BETA\n   delta  \n' > "$IGN"; go; clean_json default-path
hasnt default-path "claude.ai Beta"; hasnt default-path "delta"
has default-path "claude.ai Gamma Thing"; has default-path "epsilon"; has default-path "zeta"

# 3. Every attention name ignored: silent stdout, exit 0, cache still complete.
prep; printf 'claude.ai Beta\nclaude.ai Gamma Thing\ndelta\nepsilon\nzeta\n' > "$IGN"; go
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "all-ignored silent" || bad "all-ignored silent" "rc=$RC out=$OUT"
[ -z "$ERR" ] && ok "all-ignored stderr empty" || bad "all-ignored stderr empty" "$ERR"
for name in "claude.ai Alpha" "claude.ai Beta" "claude.ai Gamma Thing" "delta" "epsilon" "zeta"; do
  grep -q -F "$name" "$CACHE" && ok "all-ignored cache keeps '$name'" || bad "all-ignored cache keeps '$name'" "$(cat "$CACHE" 2>/dev/null)"
done

# 4. MCP_HEALTH_IGNORE_FILE pointing at a missing file: same report as no list.
prep; go "$H/nope.txt"; clean_json missing-file
[ "$OUT" = "$BASELINE" ] && ok "missing-file equals baseline" || bad "missing-file equals baseline" "$OUT"

# 5. MCP_HEALTH_IGNORE_FILE pointing at a directory: same report as no list.
prep; mkdir "$H/dir"; go "$H/dir"; clean_json unreadable-dir
[ "$OUT" = "$BASELINE" ] && ok "unreadable-dir equals baseline" || bad "unreadable-dir equals baseline" "$OUT"

# 6. Ignoring a CONNECTED name changes nothing; ignoring a DOWN name drops DOWN.
prep; printf 'claude.ai Alpha\nepsilon\n' > "$H/custom.txt"; go "$H/custom.txt"; clean_json connected-and-down
hasnt connected-and-down "DOWN"; hasnt connected-and-down "epsilon"
has connected-and-down "claude.ai Beta"; has connected-and-down "claude.ai Gamma Thing"; has connected-and-down "zeta"

# 7. The env override replaces the default path (it does not merge with it).
prep; printf 'claude.ai Beta\n' > "$IGN"; printf 'claude.ai Gamma Thing\n' > "$H/custom.txt"; go "$H/custom.txt"; clean_json override-wins
has override-wins "claude.ai Beta"; hasnt override-wins "claude.ai Gamma Thing"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
