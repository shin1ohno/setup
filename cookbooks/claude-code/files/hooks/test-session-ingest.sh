#!/usr/bin/env bash

# Black-box tests for hooks/session-ingest.rb (session search C4,
# docs/design/claude-session-search.md §6.4 / §7.3).
#
# Every case runs the hook the way Claude Code does — payload on stdin, ruby
# with -E UTF-8 --disable-gems as settings.json invokes it through ruby-shim — under `env -i` with a throwaway HOME,
# so nothing on the host (a real ccs, a real ~/.claude) can leak in. A fake
# `ccs` records its argv and process group to $CCS_RECORD and exits.
#
# Asserted for every case: exit 0, empty stdout, empty stderr. Spawn cases also
# assert the exact argv, a process group different from the hook's caller, and
# a runtime under 200 ms (bash >= 5 only; EPOCHREALTIME is needed). No-spawn
# cases wait long enough for a detached child to have written its record, so a
# hook that spawns when it should not is caught; the spawn cases are the
# positive control that the record is observable at all.
#
# The two payload fixtures are the real Stop / SessionEnd shapes captured on
# Claude Code 2.1.291 with synthetic paths (__HOME__ is substituted per case).
#
# Usage: [RUBY=/path/to/ruby] bash test-session-ingest.sh <path-to-session-ingest.rb> [fixtures-dir]
# (RUBY defaults to the ruby on PATH; pass the real binary to time the hook
# without a version-manager shim in front of it.)

set -uo pipefail
HOOK="${1:?path to session-ingest.rb}"
HOOK=$(cd "$(dirname "$HOOK")" && pwd)/$(basename "$HOOK")
FIX="${2:-$(dirname "$HOOK")/fixtures/session-ingest}"
RUBY="${RUBY:-$(command -v ruby)}"; [ -n "$RUBY" ] || { echo "FAIL ruby not found"; exit 1; }
SID="7ac4304c-044f-45d9-811a-acbe964d9494"
REL=".claude/projects/-tmp-example/$SID.jsonl"
BASE_PATH="/usr/bin:/bin"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
MY_PGID=$(ps -o pgid= -p $$ | tr -d ' ')
pass=0; fail=0; n=0

for d in /usr/bin /bin; do
  if [ -e "$d/ccs" ]; then
    echo "FAIL precondition: $d/ccs exists, the missing-ccs case cannot be tested"; exit 1
  fi
done

ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s :: %s\n' "$1" "$2"; }

# new_home: fresh HOME with ~/.claude/projects/-tmp-example/<sid>.jsonl.
new_home() {
  n=$((n+1))
  H="$ROOT/h$n"
  mkdir -p "$H/.claude/projects/-tmp-example"
  printf '{"type":"user","message":{"content":"hi"}}\n' > "$H/$REL"
  REC="$H/ccs-record"
}

# fake_ccs <dir>: install the recording fake at <dir>/ccs.
fake_ccs() {
  mkdir -p "$1"
  cat > "$1/ccs" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done > "$CCS_RECORD.tmp"
ps -o pgid= -p $$ | tr -d ' ' > "$CCS_RECORD.pgid"
mv "$CCS_RECORD.tmp" "$CCS_RECORD"
EOF
  chmod 755 "$1/ccs"
}

fixture() { # fixture <name> -> payload with __HOME__ replaced
  local body
  body=$(cat "$FIX/$1")
  printf '%s' "${body//__HOME__/$H}"
}

# invoke <stdin-string> [PATH]: sets RC, OUT, ERR, MS (-1 when unmeasurable).
invoke() {
  local input="$1" path="${2:-$BASE_PATH}" t0 t1
  t0=${EPOCHREALTIME:-}
  printf '%s' "$input" | env -i HOME="$H" PATH="$path" CCS_RECORD="$REC" \
    "$RUBY" -E UTF-8 --disable-gems "$HOOK" > "$H/stdout" 2> "$H/stderr"
  RC=$?
  t1=${EPOCHREALTIME:-}
  OUT=$(cat "$H/stdout"); ERR=$(cat "$H/stderr")
  if [ -n "$t0" ] && [ -n "$t1" ]; then
    MS=$(( (${t1/./} - ${t0/./}) / 1000 ))
  else
    MS=-1
  fi
}

wait_record() { # up to 3 s for the detached child
  local i
  for i in $(seq 1 60); do [ -f "$REC" ] && return 0; sleep 0.05; done
  return 1
}

common() { # common <name>: exit 0, silent
  [ "$RC" -eq 0 ] || { bad "$1" "exit=$RC"; return 1; }
  [ -z "$OUT" ] || { bad "$1" "stdout not empty: $OUT"; return 1; }
  [ -z "$ERR" ] || { bad "$1" "stderr not empty: $ERR"; return 1; }
  return 0
}

expect_spawn() { # expect_spawn <name>
  local name="$1" want got pg
  common "$name" || return
  if ! wait_record; then bad "$name" "ccs was not spawned"; return; fi
  want=$(printf '%s\n' ingest --file "$H/$REL" --with-subagents --quiet)
  got=$(cat "$REC")
  [ "$got" = "$want" ] || { bad "$name" "argv=[$(tr '\n' ' ' < "$REC")]"; return; }
  pg=$(cat "$REC.pgid" 2>/dev/null)
  [ -n "$pg" ] && [ "$pg" != "$MY_PGID" ] || { bad "$name" "child pgid=$pg not detached from $MY_PGID"; return; }
  if [ "$MS" -ge 0 ] && [ "$MS" -ge 200 ]; then bad "$name" "runtime ${MS} ms >= 200 ms"; return; fi
  ok "$name (${MS} ms)"
}

expect_no_spawn() { # expect_no_spawn <name>
  local name="$1"
  common "$name" || return
  sleep 0.5
  [ ! -e "$REC" ] || { bad "$name" "ccs was spawned: [$(tr '\n' ' ' < "$REC")]"; return; }
  ok "$name"
}

# --- spawn cases -------------------------------------------------------------

new_home; fake_ccs "$H/.local/bin"
invoke "$(fixture stop.json)"
expect_spawn "Stop payload, ccs in ~/.local/bin"

new_home; fake_ccs "$H/.local/bin"
invoke "$(fixture session-end.json)"
expect_spawn "SessionEnd payload, ccs in ~/.local/bin"

new_home; fake_ccs "$H/alt-bin"
invoke "$(fixture stop.json)" "$H/alt-bin:$BASE_PATH"
expect_spawn "ccs found on PATH only"

new_home; fake_ccs "$H/.local/bin"; fake_ccs "$H/alt-bin"
printf '#!/bin/sh\nexit 0\n' > "$H/alt-bin/ccs"
invoke "$(fixture stop.json)" "$H/alt-bin:$BASE_PATH"
expect_spawn "~/.local/bin/ccs wins over PATH"

# --- no-spawn cases ----------------------------------------------------------

new_home
invoke "$(fixture stop.json)"
expect_no_spawn "ccs missing"
if grep -q "session-ingest session=$SID: ccs not found" "$H/.claude/session-search.log" 2>/dev/null; then
  ok "ccs missing -> log line written"
else
  bad "ccs missing -> log line written" "log: $(cat "$H/.claude/session-search.log" 2>/dev/null)"
fi

new_home; fake_ccs "$H/.local/bin"
invoke '{"session_id":"x","transcript_path":'
expect_no_spawn "malformed JSON"

new_home; fake_ccs "$H/.local/bin"
invoke ''
expect_no_spawn "empty stdin"

new_home; fake_ccs "$H/.local/bin"
invoke '["not","an","object"]'
expect_no_spawn "JSON array payload"

new_home; fake_ccs "$H/.local/bin"
invoke "{\"session_id\":\"$SID\",\"hook_event_name\":\"Stop\"}"
expect_no_spawn "transcript_path missing"

new_home; fake_ccs "$H/.local/bin"
invoke "{\"session_id\":\"$SID\",\"transcript_path\":42}"
expect_no_spawn "transcript_path not a string"

new_home; fake_ccs "$H/.local/bin"
mkdir -p "$H/elsewhere"; printf '{}\n' > "$H/elsewhere/$SID.jsonl"
invoke "{\"session_id\":\"$SID\",\"transcript_path\":\"$H/elsewhere/$SID.jsonl\"}"
expect_no_spawn "path outside ~/.claude/projects/"

new_home; fake_ccs "$H/.local/bin"
invoke "{\"session_id\":\"$SID\",\"transcript_path\":\"$H/.claude/projects/-tmp-example/missing.jsonl\"}"
expect_no_spawn "non-existent transcript"

new_home; fake_ccs "$H/.local/bin"
printf '{}\n' > "$H/.claude/escape.jsonl"
invoke "{\"session_id\":\"$SID\",\"transcript_path\":\"$H/.claude/projects/../escape.jsonl\"}"
expect_no_spawn "'..' escape out of projects/"

new_home; fake_ccs "$H/.local/bin"
mkdir -p "$H/elsewhere"; printf '{}\n' > "$H/elsewhere/target.jsonl"
ln -s "$H/elsewhere/target.jsonl" "$H/.claude/projects/-tmp-example/link.jsonl"
invoke "{\"session_id\":\"$SID\",\"transcript_path\":\"$H/.claude/projects/-tmp-example/link.jsonl\"}"
expect_no_spawn "symlink pointing outside projects/"

new_home; fake_ccs "$H/.local/bin"
printf '{}\n' > "$H/.claude/projects/-tmp-example/notes.txt"
invoke "{\"session_id\":\"$SID\",\"transcript_path\":\"$H/.claude/projects/-tmp-example/notes.txt\"}"
expect_no_spawn "not a .jsonl file"

new_home; fake_ccs "$H/.local/bin"
mkdir -p "$H/.claude/projects/-tmp-example/dir.jsonl"
invoke "{\"session_id\":\"$SID\",\"transcript_path\":\"$H/.claude/projects/-tmp-example/dir.jsonl\"}"
expect_no_spawn "directory named *.jsonl"

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
