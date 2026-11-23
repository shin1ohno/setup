#!/usr/bin/env bash

# Black-box tests for hooks/cos-worker-state.rb.  Each case runs the hook under
# a scrubbed environment with a host-shaped payload on stdin (field names from
# the Claude Code 2.1.330 hook input schemas) against a throwaway state
# directory, then asserts what state-<n>.json and events-<n>.jsonl hold.
#
# Both polarities are covered on purpose: a no-op fails the recording cases, a
# version that writes without its variables, creates the task directory or
# follows a symlink fails the inert and refusal cases, and a version that copies
# worker text verbatim fails the cleaning cases.  The last section checks the
# settings.json and cookbook wiring and runs the registered command under
# environments that try to change what Ruby loads.
#
# Usage: bash test-cos-worker-state.sh <path-to-hook.rb> [settings.json]

set -uo pipefail
HOOK="${1:?path to cos-worker-state.rb}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SETTINGS="${2:-$HERE/../settings.json}"
COOKBOOK="$HERE/../.."
# Resolved before HOME changes: a version-manager shim breaks under a throwaway HOME.
RUBY="${RUBY:-$(ruby -e 'print RbConfig.ruby')}"
D=$(mktemp -d)
trap 'chmod -R u+w "$D"; rm -rf "$D"' EXIT
pass=0; fail=0

TASK=0123456789abcdef
ATTEMPT=2
mkdir -p "$D/home" "$D/evil"

check() { # check <name> <condition result 0|1> [detail]
  if [ "$2" = 0 ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$1"
  else
    fail=$((fail+1)); printf 'FAIL %s :: %s\n' "$1" "${3:-}"
  fi
}

CASE=0
new_case() { # new_case -> fresh state dir with the task directory
  CASE=$((CASE+1))
  STATE="$D/state$CASE"
  mkdir -p "$STATE/$TASK"
  SF="$STATE/$TASK/state-$ATTEMPT.json"
  EF="$STATE/$TASK/events-$ATTEMPT.jsonl"
}

hook() { # hook <payload> KEY=VALUE... ; runs the hook with only those variables set
  local payload=$1; shift
  printf '%s' "$payload" | env -i PATH=/usr/bin:/bin HOME="$D/home" "$@" \
    "$RUBY" --disable-gems -E UTF-8 "$HOOK" >"$D/out" 2>"$D/err"
  HOOK_RC=$?
  HOOK_OUT=$(cat "$D/out")
}

fire() { # fire <payload> [KEY=VALUE overrides...] ; with the valid worker env
  local payload=$1; shift
  hook "$payload" "COS_WORKER_TASK_ID=$TASK" "COS_WORKER_ATTEMPT=$ATTEMPT" "COS_STATE_DIR=$STATE" "$@"
}

# The expression is always a literal written in this file, never data.
jget() { # jget <file> <ruby expression over d> ; prints the value, "ERR" if unreadable
  "$RUBY" -rjson -e 'd = JSON.parse(File.read(ARGV[0])); v = eval(ARGV[1]); print(v.is_a?(String) ? v : JSON.generate(v))' \
    "$1" "$2" 2>/dev/null || printf 'ERR'
}

files_in() { find "$1" -type f -o -type l 2>/dev/null | wc -l | tr -d ' '; }

quiet() { [ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ]; }

PR_BASH='{"session_id":"3f1c0d2e-5a4b-4c3d-9e8f-001122334455","transcript_path":"/tmp/none.jsonl","cwd":"/tmp","permission_mode":"default","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"git push origin feat/x","description":"Push"},"permission_suggestions":[]}'
NOTE_PERM='{"session_id":"3f1c0d2e-5a4b-4c3d-9e8f-001122334455","hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}'
NOTE_IDLE='{"session_id":"3f1c0d2e-5a4b-4c3d-9e8f-001122334455","hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}'
STOP_FAIL='{"session_id":"3f1c0d2e-5a4b-4c3d-9e8f-001122334455","hook_event_name":"StopFailure","error":"rate_limit","error_details":"429 Too Many Requests"}'
SESSION_END='{"session_id":"3f1c0d2e-5a4b-4c3d-9e8f-001122334455","hook_event_name":"SessionEnd","reason":"prompt_input_exit"}'
bash_ok() { # bash_ok <command> <stdout> ; a PostToolUse(Bash) payload
  "$RUBY" -rjson -e 'print JSON.generate("session_id" => "3f1c0d2e-5a4b-4c3d-9e8f-001122334455", "hook_event_name" => "PostToolUse",
    "tool_name" => "Bash", "tool_input" => {"command" => ARGV[0]}, "tool_use_id" => "toolu_01",
    "tool_response" => {"stdout" => ARGV[1], "stderr" => "", "interrupted" => false, "isImage" => false})' "$1" "$2"
}
bash_fail() { # bash_fail <command> <error> ; a PostToolUseFailure(Bash) payload
  "$RUBY" -rjson -e 'print JSON.generate("session_id" => "3f1c0d2e-5a4b-4c3d-9e8f-001122334455", "hook_event_name" => "PostToolUseFailure",
    "tool_name" => "Bash", "tool_input" => {"command" => ARGV[0]}, "tool_use_id" => "toolu_02", "error" => ARGV[1], "is_interrupt" => false)' "$1" "$2"
}

# --- inert outside a CoS worker ----------------------------------------------

new_case
hook "$PR_BASH"
[ "$(files_in "$STATE")" = 0 ] && quiet; check "no CoS variables: no files" $? "files=$(files_in "$STATE") rc=$HOOK_RC"

new_case
hook "$PR_BASH" "COS_WORKER_TASK_ID=$TASK" "COS_STATE_DIR=$STATE"
[ "$(files_in "$STATE")" = 0 ] && quiet; check "missing COS_WORKER_ATTEMPT: no files" $?

new_case
hook "$PR_BASH" "COS_WORKER_ATTEMPT=$ATTEMPT" "COS_STATE_DIR=$STATE"
[ "$(files_in "$STATE")" = 0 ] && quiet; check "missing COS_WORKER_TASK_ID: no files" $?

NL=$'\n'
for v in '../escape' '0123456789ABCDEF' '0123456789abcde' '0123456789abcdef0' "0123456789abcdef${NL}" '$(touch PWNED)'; do
  new_case; mkdir -p "$STATE/$v" 2>/dev/null
  fire "$PR_BASH" "COS_WORKER_TASK_ID=$v"
  [ "$(files_in "$STATE")" = 0 ] && quiet; rc=$?; check "bad task id $(printf '%q' "$v"): no files" $rc "files=$(files_in "$STATE")"
done
for v in 0 01 1000 x "2${NL}"; do
  new_case
  fire "$PR_BASH" "COS_WORKER_ATTEMPT=$v"
  [ "$(files_in "$STATE")" = 0 ] && quiet; rc=$?; check "bad attempt $(printf '%q' "$v"): no files" $rc
done
new_case
fire "$PR_BASH" "COS_STATE_DIR=relative/dir"
[ "$(files_in "$STATE")" = 0 ] && quiet; check "relative COS_STATE_DIR: no files" $?
[ ! -e PWNED ]; check "nothing was executed from a value" $?

CASE=$((CASE+1)); STATE="$D/state$CASE"; mkdir -p "$STATE"
fire "$PR_BASH"
[ ! -e "$STATE/$TASK" ] && quiet; check "missing task directory: not created" $? "$(ls -la "$STATE")"

CASE=$((CASE+1)); STATE="$D/state$CASE"; mkdir -p "$STATE" "$D/elsewhere$CASE"; ln -s "$D/elsewhere$CASE" "$STATE/$TASK"
fire "$PR_BASH"
[ "$(files_in "$D/elsewhere$CASE")" = 0 ] && quiet; check "symlinked task directory: nothing written" $?

# --- dialogs ------------------------------------------------------------------

new_case
fire "$PR_BASH"
[ "$(jget "$SF" 'd["status"]')" = blocked ] && [ "$(jget "$SF" 'd["blocked"]["tool"]')" = Bash ] \
  && [ "$(jget "$SF" 'd["blocked"]["command"]')" = "git push origin feat/x" ] && quiet
check "PermissionRequest: blocked with the exact command" $? "$(cat "$SF" 2>&1) out=$HOOK_OUT"
[ "$(jget "$SF" 'd["task_id"]')" = "$TASK" ] && [ "$(jget "$SF" 'd["attempt"]')" = 2 ] \
  && [ "$(jget "$SF" 'd["session_id"]')" = 3f1c0d2e-5a4b-4c3d-9e8f-001122334455 ]
check "state names the task, attempt and session" $?
[ "$(stat -c %a "$SF" 2>/dev/null || stat -f %Lp "$SF")" = 600 ]; check "state file is private (0600)" $?
[ "$(wc -l < "$EF" | tr -d ' ')" = 1 ] && [ "$(jget "$EF" 'd["event"]')" = PermissionRequest ]
check "one event line appended" $? "$(cat "$EF" 2>&1)"
fire "$NOTE_PERM"
[ "$(jget "$SF" 'd["blocked"]["command"]')" = "git push origin feat/x" ] && [ "$(wc -l < "$EF" | tr -d ' ')" = 2 ]
check "a later permission notice keeps the exact command" $? "$(cat "$SF")"

new_case
fire "$NOTE_PERM"
[ "$(jget "$SF" 'd["status"]')" = blocked ] && [ "$(jget "$SF" 'd["blocked"]["tool"]')" = Bash ] \
  && [ "$(jget "$SF" 'd["blocked"]["command"]')" = null ]
check "permission notice alone: blocked, tool from the message" $? "$(cat "$SF")"

new_case
fire '{"session_id":"3f1c0d2e-5a4b-4c3d-9e8f-001122334455","hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which branch should I push?","header":"Branch","options":[]}]}}'
[ "$(jget "$SF" 'd["status"]')" = asking ] && [ "$(jget "$SF" 'd["asking"]["question"]')" = "Which branch should I push?" ] \
  && [ "$(jget "$SF" 'd["blocked"]')" = null ]
check "AskUserQuestion: asking with the question" $? "$(cat "$SF")"

new_case
fire '{"session_id":"3f1c0d2e-5a4b-4c3d-9e8f-001122334455","hook_event_name":"Notification","message":"MCP server wants input","notification_type":"elicitation_dialog"}'
[ "$(jget "$SF" 'd["status"]')" = asking ]; check "elicitation notice: asking" $? "$(cat "$SF")"

new_case
fire "$PR_BASH"; fire "$NOTE_IDLE"
[ "$(jget "$SF" 'd["status"]')" = idle ] && [ "$(jget "$SF" 'd["blocked"]')" = null ]
check "idle prompt after a dialog: idle, dialog cleared" $? "$(cat "$SF")"

new_case
fire '{"hook_event_name":"Notification","message":"Signed in","notification_type":"auth_success"}'
[ "$(jget "$SF" 'd["status"]')" = null ] && [ "$(wc -l < "$EF" | tr -d ' ')" = 1 ]
check "other notices are logged without a status" $? "$(cat "$SF")"

# --- errors and ends ----------------------------------------------------------

new_case
fire "$STOP_FAIL"
[ "$(jget "$SF" 'd["status"]')" = error ] && [ "$(jget "$SF" 'd["error"]["message"]')" = rate_limit ] \
  && [ "$(jget "$SF" 'd["error"]["details"]')" = "429 Too Many Requests" ] && quiet
check "StopFailure: error with its class and details" $? "$(cat "$SF")"
fire "$NOTE_IDLE"
[ "$(jget "$SF" 'd["status"]')" = error ]; check "a later idle prompt keeps the error" $? "$(cat "$SF")"

new_case
fire "$SESSION_END"
[ "$(jget "$SF" 'd["status"]')" = ended ] && [ "$(jget "$SF" 'd["ended"]["reason"]')" = prompt_input_exit ]
check "SessionEnd: ended with the reason" $? "$(cat "$SF")"

# --- milestones from Bash -----------------------------------------------------

new_case
fire "$PR_BASH"
fire "$(bash_ok 'git add a && git commit -m "x: y"' "$(printf '[feat/x 1a2b3c4] chief-of-staff: record worker state\n 2 files changed')")"
[ "$(jget "$SF" 'd["status"]')" = working ] && [ "$(jget "$SF" 'd["blocked"]')" = null ] \
  && [ "$(jget "$SF" 'd["milestones"][-1]["kind"]')" = commit ] \
  && [ "$(jget "$SF" 'd["milestones"][-1]["sha"]')" = 1a2b3c4 ] \
  && [ "$(jget "$SF" 'd["milestones"][-1]["subject"]')" = "chief-of-staff: record worker state" ]
check "git commit: working, subject and sha from the output" $? "$(cat "$SF")"

new_case
fire "$(bash_ok "$(printf "git commit -F - <<'EOF'\nhooks: heredoc subject\n\nbody\nEOF")" '')"
[ "$(jget "$SF" 'd["milestones"][-1]["subject"]')" = "hooks: heredoc subject" ]
check "git commit without output: subject from the heredoc" $? "$(cat "$SF")"

new_case
fire "$(bash_ok 'gh pr create --base main --title t --body-file -' "$(printf 'Creating pull request\nhttps://github.com/o/r/pull/1234\n')")"
[ "$(jget "$SF" 'd["milestones"][-1]["kind"]')" = pr ] && [ "$(jget "$SF" 'd["milestones"][-1]["url"]')" = https://github.com/o/r/pull/1234 ]
check "gh pr create: the PR URL" $? "$(cat "$SF")"

new_case
fire "$(bash_fail 'bash cookbooks/claude-code/files/hooks/test-cos-worker-state.sh x.rb' "$(printf 'Exit code 3\nFAIL something')")"
[ "$(jget "$SF" 'd["milestones"][-1]["kind"]')" = test-failed ] && [ "$(jget "$SF" 'd["milestones"][-1]["exit_code"]')" = 3 ] \
  && [ "$(jget "$SF" 'd["milestones"][-1]["command"]')" = "bash cookbooks/claude-code/files/hooks/test-cos-worker-state.sh x.rb" ]
check "failing test command: command and exit code" $? "$(cat "$SF")"

new_case
fire "$(bash_fail 'ls /nope' 'Exit code 2')"
fire "$(bash_ok 'cargo test' 'test result: ok')"
fire "$(bash_ok 'git status' '[feat/x 1a2b3c4] not a commit')"
[ "$(jget "$SF" 'd["milestones"].size')" = 0 ] && [ "$(jget "$SF" 'd["status"]')" = working ]
check "a failing non-test, a passing test and git status are no milestones" $? "$(cat "$SF")"

new_case
fire '{"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"/x"},"tool_response":{}}'
[ "$(files_in "$STATE")" = 0 ] && quiet; check "a non-Bash PostToolUse writes nothing" $?
fire '{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"done"}'
[ "$(files_in "$STATE")" = 0 ]; check "an unregistered event writes nothing" $?

new_case
for i in $(seq 1 25); do
  fire "$(bash_ok "git commit -m m$i" "[main abc$(printf '%04d' "$i")] subject $i")"
done
[ "$(jget "$SF" 'd["milestones"].size')" = 20 ] && [ "$(jget "$SF" 'd["milestones"][0]["subject"]')" = "subject 6" ] \
  && [ "$(jget "$SF" 'd["milestones"][-1]["subject"]')" = "subject 25" ]
check "milestones keep the last 20" $? "size=$(jget "$SF" 'd["milestones"].size')"

new_case
for i in $(seq 1 10); do
  ( fire "$(bash_ok "git commit -m p$i" "[main def$(printf '%04d' "$i")] parallel $i")" ) &
done
wait
[ "$(jget "$SF" 'd["milestones"].size')" = 10 ] && [ "$(wc -l < "$EF" | tr -d ' ')" = 10 ]
check "10 concurrent events lose no milestone" $? "size=$(jget "$SF" 'd["milestones"].size') events=$(wc -l < "$EF")"
[ "$(find "$STATE/$TASK" -name '.*tmp' | wc -l | tr -d ' ')" = 0 ]; check "no temp files are left behind" $?

# --- worker text is cleaned ---------------------------------------------------

new_case
fire '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"git push\u001b[31m origin\u0007 main\u202e\u2066\u200b\u0000\nrm -rf x\u001b]0;title\u0007\u0085done\uDB40\uDC41"}}'
got=$(jget "$SF" 'd["blocked"]["command"]')
[ "$got" = "git push origin main rm -rf x done" ]; check "escapes, controls, bidi and zero-width removed; newline is a space" $? "got=$(printf '%q' "$got")"
"$RUBY" -rjson -e '
  walk = ->(v) { v.is_a?(Hash) ? v.values.flat_map(&walk) : v.is_a?(Array) ? v.flat_map(&walk) : [v] }
  bad = /[\u0000-\u001f\u007f-\u009f\u061c\u200b-\u200f\u202a-\u202e\u2060-\u2069\ufeff\u{e0000}-\u{e007f}]/
  exit(walk.(JSON.parse(File.read(ARGV[0]))).grep(String).none? { |s| s.match?(bad) } ? 0 : 1)' "$SF"
check "no control or bidi character anywhere in the state file" $?

new_case
long=$("$RUBY" -e 'print "x" + "\u3042" * 200')
fire "$("$RUBY" -rjson -e 'print JSON.generate("hook_event_name" => "PermissionRequest", "tool_name" => "Bash", "tool_input" => {"command" => ARGV[0]})' "$long")"
"$RUBY" -rjson -e 'c = JSON.parse(File.read(ARGV[0]))["blocked"]["command"]; exit(c.bytesize <= 300 && c.valid_encoding? && c.bytesize >= 295 && c.end_with?("\u3042") ? 0 : 1)' "$SF"
check "a long value is cut to 300 bytes on a character boundary" $? "$(jget "$SF" 'd["blocked"]["command"].bytesize')"

# --- refusals and caps --------------------------------------------------------

new_case
printf 'keep' > "$STATE/victim"; ln -s "$STATE/victim" "$SF"
fire "$PR_BASH"
[ -L "$SF" ] && [ "$(cat "$STATE/victim")" = keep ] && quiet; check "symlinked state file: refused, target untouched" $? "$(ls -la "$STATE/$TASK")"

new_case
printf 'keep' > "$STATE/victim"; ln -s "$STATE/victim" "$EF"
fire "$PR_BASH"
[ -L "$EF" ] && [ "$(cat "$STATE/victim")" = keep ]; check "symlinked event log: refused, target untouched" $?

new_case
"$RUBY" -e 'File.write(ARGV[0], ("x" * 1023 + "\n") * 255 + "x" * 1000 + "\n")' "$EF"
before=$(wc -c < "$EF" | tr -d ' ')
fire "$PR_BASH"
after=$(wc -c < "$EF" | tr -d ' ')
[ "$before" = "$after" ] && [ "$(jget "$SF" 'd["status"]')" = blocked ]
check "event log stops at 256 KiB while the state still updates" $? "before=$before after=$after"
new_case
"$RUBY" -e 'File.write(ARGV[0], "x" * (200 * 1024))' "$EF"
fire "$PR_BASH"
[ "$(wc -c < "$EF" | tr -d ' ')" -gt $((200 * 1024)) ]; check "event log under the cap still grows" $?

# --- never fails the worker's turn --------------------------------------------

for p in 'not json' '' '[]' '{"hook_event_name":42}'; do
  new_case
  fire "$p"
  quiet && [ "$(files_in "$STATE")" = 0 ]; rc=$?; check "stdin $(printf '%q' "$p"): exit 0, no output, no files" $rc "rc=$HOOK_RC out=$HOOK_OUT"
done
new_case
printf '{not json' > "$SF"
fire "$PR_BASH"
[ "$(jget "$SF" 'd["status"]')" = blocked ] && quiet; check "a corrupt state file is replaced" $?

new_case
chmod 555 "$STATE/$TASK"
fire "$PR_BASH"
chmod 755 "$STATE/$TASK"
[ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ]; check "unwritable task dir: exit 0, no stdout" $? "rc=$HOOK_RC out=$HOOK_OUT"

# --- wiring -------------------------------------------------------------------

WIRING=$("$RUBY" -rjson -e '
  hooks = JSON.parse(File.read(ARGV[0]))["hooks"]
  want = {"PermissionRequest" => nil, "Notification" => nil, "StopFailure" => nil, "SessionEnd" => nil,
          "PostToolUse" => "Bash", "PostToolUseFailure" => "Bash"}
  cmds = want.map do |event, matcher|
    hits = (hooks[event] || []).flat_map { |g| g["hooks"].map { |h| [g["matcher"], h] } }
                               .select { |_, h| h["command"].to_s.include?("cos-worker-state.rb") }
    abort "#{event}: expected one registration, found #{hits.size}" unless hits.size == 1
    abort "#{event}: matcher #{hits[0][0].inspect}" if matcher && hits[0][0] != matcher
    abort "#{event}: no timeout" unless hits[0][1]["timeout"].is_a?(Integer)
    hits[0][1]["command"]
  end
  abort "registrations differ" unless cmds.uniq.size == 1
  others = (hooks.keys - want.keys).select { |e| hooks[e].to_s.include?("cos-worker-state.rb") }
  abort "also registered for #{others}" unless others.empty?
  print cmds[0]' "$SETTINGS" 2>&1)
case "$WIRING" in
  "/usr/bin/env -u RUBYOPT -u RUBYLIB -u RUBYPATH ~/.claude/hooks/ruby-shim --disable-gems ~/.claude/hooks/cos-worker-state.rb")
    check "settings.json registers it once per event with one cleaned command" 0 ;;
  *) check "settings.json registers it once per event with one cleaned command" 1 "$WIRING" ;;
esac
for f in "$COOKBOOK/default.rb" "$COOKBOOK/testdata/default-before-distribution-split.rb"; do
  grep -E '^%w\(.*\bcos-worker-state\.rb\b.*\)\.each do \|file_name\|' "$f" | grep -q 'pre-commit-test.rb'
  rc=$?; check "deployed by the hook list in $(basename "$f")" $rc
done

mkdir -p "$D/home/.claude/hooks"
cp "$HOOK" "$D/home/.claude/hooks/cos-worker-state.rb"
cp "$HERE/ruby-shim" "$D/home/.claude/hooks/ruby-shim"
chmod +x "$D/home/.claude/hooks/ruby-shim"
BLOCK='{"decision":"block","reason":"worker chosen"}'
printf 'puts %s\n' "'$BLOCK'" > "$D/evil/json.rb"
printf 'puts %s\n' "'$BLOCK'" > "$D/evil/opt.rb"
hostile() { # hostile <name> KEY=VALUE... ; the registered command under that environment
  local name=$1; shift
  new_case
  printf '%s' "$PR_BASH" | env -i PATH="$(dirname "$RUBY"):/usr/bin:/bin" HOME="$D/home" \
    "COS_WORKER_TASK_ID=$TASK" "COS_WORKER_ATTEMPT=$ATTEMPT" "COS_STATE_DIR=$STATE" "$@" \
    /bin/sh -c "$WIRING" >"$D/out" 2>"$D/err"
  HOOK_RC=$?; HOOK_OUT=$(cat "$D/out")
  [ "$(jget "$SF" 'd["blocked"]["command"]')" = "git push origin feat/x" ] && quiet
  check "registered command, $name: records, prints nothing" $? "rc=$HOOK_RC out=$HOOK_OUT err=$(cat "$D/err")"
}
hostile "plain"
hostile "RUBYLIB shadows json" "RUBYLIB=$D/evil"
hostile "RUBYOPT loads a file" "RUBYOPT=-r$D/evil/opt.rb"

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" = 0 ]
