#!/usr/bin/env bash

# Black-box tests for hooks/recall-at-start.rb and its wiring.
#
# T1  config enabled -> JSON with hookEventName SessionStart and an
#     additionalContext holding the tool name, the ToolSearch select string,
#     the M3 marker, the "forbid"/"fixed reply" exemption; under 10000 chars.
# T2  no config / enabled:false / enabled not true / malformed JSON / non-object
#     JSON / unreadable (directory) / bad tool name -> empty stdout, empty
#     stderr, exit 0.
# T3  wiring: settings.json SessionStart[startup] registers the hook and
#     default.rb distributes it, and memory-mirror places the config. Run
#     against a copy with the registration removed, this must fail (negative
#     control, asserted below).
# The hook runs as Claude Code runs it (ruby -E UTF-8) under `env -i` with a
# throwaway HOME. It must not need network, credentials or any subprocess.
#
# Usage: [RUBY=/path/to/ruby] bash test-recall-at-start.sh <path-to-recall-at-start.rb>

set -uo pipefail
HOOK="${1:?path to recall-at-start.rb}"
HOOK=$(cd "$(dirname "$HOOK")" && pwd)/$(basename "$HOOK")
COOKBOOK=$(cd "$(dirname "$HOOK")/../.." && pwd)   # cookbooks/claude-code
MIRROR="$COOKBOOK/../memory-mirror/default.rb"
RUBY="${RUBY:-$(ruby -e 'print RbConfig.ruby')}"
[ -x "$RUBY" ] || { echo "FAIL ruby not found"; exit 1; }
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0; n=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s :: %s\n' "$1" "$2"; }

TOOL=mcp__claude_ai_memory__recall

# run [config-file-or-none]: sets OUT ERR RC. Default path = $H/.claude/recall-at-start.json.
prep() { n=$((n+1)); H="$ROOT/h$n"; mkdir -p "$H/.claude"; CFG="$H/.claude/recall-at-start.json"; }
go() {
  OUT=$(env -i HOME="$H" PATH=/usr/bin:/bin LANG= "$RUBY" -E UTF-8 "$HOOK" 2>"$H/stderr"); RC=$?
  ERR=$(cat "$H/stderr")
}
silent() { # name
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] && ok "$1 silent exit 0" || bad "$1 silent exit 0" "rc=$RC out=$OUT err=$ERR"
}

# T1: enabled
prep; printf '{"enabled":true,"tool":"%s"}' "$TOOL" > "$CFG"; go
[ "$RC" -eq 0 ] && [ -z "$ERR" ] && ok "enabled exit 0, stderr empty" || bad "enabled exit 0, stderr empty" "rc=$RC err=$ERR"
CTX=$(printf '%s' "$OUT" | "$RUBY" -rjson -e 'j=JSON.parse(STDIN.read); abort("event") unless j.dig("hookSpecificOutput","hookEventName")=="SessionStart"; print j.dig("hookSpecificOutput","additionalContext")' 2>&1) \
  && ok "enabled JSON shape" || bad "enabled JSON shape" "$CTX | $OUT"
for needle in "Memory recall at session start:" "$TOOL" "ToolSearch query \"select:$TOOL\"" "before the first reply" "forbid memory tools" "fixed reply" "take precedence"; do
  case "$CTX" in *"$needle"*) ok "enabled text has '$needle'";; *) bad "enabled text has '$needle'" "$CTX";; esac
done
[ "${#CTX}" -lt 10000 ] && [ "${#CTX}" -gt 100 ] && ok "enabled text length ${#CTX}" || bad "enabled text length" "${#CTX}"
# tool name comes from config
prep; printf '{"enabled":true,"tool":"mcp__other__recall"}' > "$CFG"; go
case "$OUT" in *"select:mcp__other__recall"*) ok "tool name from config";; *) bad "tool name from config" "$OUT";; esac

# T2: every off / broken shape is silent
prep; go; silent "no config"
prep; printf '{"enabled":false,"tool":"%s"}' "$TOOL" > "$CFG"; go; silent "enabled:false"
prep; printf '{"enabled":"true","tool":"%s"}' "$TOOL" > "$CFG"; go; silent "enabled not boolean true"
prep; printf '{"tool":"%s"}' "$TOOL" > "$CFG"; go; silent "enabled missing"
prep; printf '{"enabled":true,' > "$CFG"; go; silent "malformed JSON"
prep; printf '[1,2]' > "$CFG"; go; silent "non-object JSON"
prep; : > "$CFG"; go; silent "empty file"
prep; mkdir "$CFG"; go; silent "config is a directory"
prep; printf '{"enabled":true}' > "$CFG"; go; silent "tool missing"
prep; printf '{"enabled":true,"tool":"Bash"}' > "$CFG"; go; silent "tool not an mcp name"
prep; printf '{"enabled":true,"tool":"mcp__x\\" injected"}' > "$CFG"; go; silent "tool with quote"
prep; printf '{"enabled":true,"tool":42}' > "$CFG"; go; silent "tool not a string"

# T3: wiring — a function so the negative control can reuse it on a mutated copy.
wiring() { # settings default.rb mirror -> prints failures, rc 0 when wired
  local s="$1" d="$2" m="$3" rc=0
  "$RUBY" -rjson -e '
    j = JSON.parse(File.read(ARGV[0]))
    g = j.dig("hooks","SessionStart").find { |x| x["matcher"] == "startup" } or abort("no startup group")
    cmds = g["hooks"].map { |h| h["command"] }
    abort("recall-at-start.rb not registered under SessionStart[startup]") unless cmds.any? { |c| c.include?("hooks/recall-at-start.rb") }
    abort("must not be SubagentStart-registered") if (j.dig("hooks","SubagentStart") || []).to_s.include?("recall-at-start")
  ' "$s" || rc=1
  grep -q 'recall-at-start\.rb' "$d" || { echo "default.rb does not distribute recall-at-start.rb"; rc=1; }
  grep -q 'recall-at-start\.json' "$m" || { echo "memory-mirror does not place recall-at-start.json"; rc=1; }
  return $rc
}
if W=$(wiring "$COOKBOOK/files/settings.json" "$COOKBOOK/default.rb" "$MIRROR" 2>&1); then ok "wiring present"; else bad "wiring present" "$W"; fi
# negative controls: each removal must make the wiring check fail
mkdir -p "$ROOT/neg"
"$RUBY" -rjson -e 'j=JSON.parse(File.read(ARGV[0])); j["hooks"]["SessionStart"].each { |g| g["hooks"].reject! { |h| h["command"].include?("recall-at-start") } }; File.write(ARGV[1], JSON.generate(j))' "$COOKBOOK/files/settings.json" "$ROOT/neg/settings.json"
if wiring "$ROOT/neg/settings.json" "$COOKBOOK/default.rb" "$MIRROR" >/dev/null 2>&1; then bad "negative control: settings registration removed" "wiring still passes"; else ok "negative control: settings registration removed fails"; fi
sed 's/recall-at-start\.rb//g' "$COOKBOOK/default.rb" > "$ROOT/neg/default.rb"
if wiring "$COOKBOOK/files/settings.json" "$ROOT/neg/default.rb" "$MIRROR" >/dev/null 2>&1; then bad "negative control: distribution removed" "wiring still passes"; else ok "negative control: distribution removed fails"; fi
sed 's/recall-at-start\.json//g' "$MIRROR" > "$ROOT/neg/mirror.rb"
if wiring "$COOKBOOK/files/settings.json" "$COOKBOOK/default.rb" "$ROOT/neg/mirror.rb" >/dev/null 2>&1; then bad "negative control: config placement removed" "wiring still passes"; else ok "negative control: config placement removed fails"; fi
# the hook itself removed -> T1 would fail: assert that a missing hook yields no JSON
OUT=$(env -i HOME="$ROOT" PATH=/usr/bin:/bin "$RUBY" "$ROOT/nonexistent.rb" 2>/dev/null); [ -z "$OUT" ] && ok "negative control: missing hook produces no context" || bad "negative control: missing hook" "$OUT"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
