#!/usr/bin/env bash

# Black-box tests for hooks/warn-background-launch-no-progress.rb.  Each case
# writes a synthetic Stop-hook transcript, pipes the payload to the hook, and
# asserts only whether the hook printed a reminder (FIRE) or stayed quiet
# (SILENT) — the hook must never block and never raise, so a non-empty stderr
# also counts as output and fails the SILENT cases.
#
# Both polarities are covered on purpose: an over-eager version that always
# fires passes only the FIRE cases, and a no-op version passes only the SILENT
# ones, so neither survives the suite.
#
# Usage: bash test-warn-background-launch-no-progress.sh <path-to-hook.rb>

set -uo pipefail
HOOK="${1:?path to warn-background-launch-no-progress.rb}"
D=$(mktemp -d)
pass=0; fail=0

mk() { # mk <file> <lines...>
  local f="$1"; shift
  : > "$f"
  for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
}

run() { # run <name> <transcript> <expect: FIRE|SILENT>
  local name="$1" t="$2" expect="$3"
  local out
  out=$(printf '{"transcript_path":"%s"}' "$t" | ruby "$HOOK" 2>&1)
  local got="SILENT"; [ -n "$out" ] && got="FIRE"
  if [ "$got" = "$expect" ]; then
    pass=$((pass+1)); printf 'ok   %-42s %s\n' "$name" "$got"
  else
    fail=$((fail+1)); printf 'FAIL %-42s want=%s got=%s :: %s\n' "$name" "$expect" "$got" "$out"
  fi
}

A_LAUNCH_TASK='{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu1","name":"Task","input":{"prompt":"go"}}]}}'
A_LAUNCH_WF='{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu9","name":"Workflow","input":{"script":"x"}}]}}'
A_LAUNCH_BG='{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu2","name":"Bash","input":{"command":"make all","run_in_background":true}}]}}'
A_BASH_FG='{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu3","name":"Bash","input":{"command":"ls","run_in_background":false}}]}}'
A_CLOSE='{"type":"assistant","message":{"content":[{"type":"text","text":"起動しました。完了時に通知が来ます。"}]}}'
A_PROGRESS='{"type":"assistant","message":{"content":[{"type":"text","text":"進行中: done 3/8、最終活動 2 分前です。"}]}}'
A_MONITOR='{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu4","name":"Monitor","input":{}}]}}'
A_BASH_JOURNAL='{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu5","name":"Bash","input":{"command":"tail -3 /x/journal.jsonl"}}]}}'
U_NOTIF='{"type":"user","message":{"content":[{"type":"text","text":"<task-notification>done</task-notification>"}]}}'
U_RESULT='{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"finished"}]}}'
U_PLAIN='{"type":"user","message":{"content":[{"type":"text","text":"次いこう"}]}}'

mk "$D/1.jsonl" "$A_LAUNCH_TASK" "$A_CLOSE"
run "Task launch, no observation" "$D/1.jsonl" FIRE

mk "$D/2.jsonl" "$A_LAUNCH_WF" "$A_CLOSE"
run "Workflow launch, no observation" "$D/2.jsonl" FIRE

mk "$D/3.jsonl" "$A_LAUNCH_BG" "$A_CLOSE"
run "Bash run_in_background, no observation" "$D/3.jsonl" FIRE

mk "$D/4.jsonl" "$A_LAUNCH_TASK" "$A_MONITOR" "$A_CLOSE"
run "launch then Monitor" "$D/4.jsonl" SILENT

mk "$D/5.jsonl" "$A_LAUNCH_TASK" "$A_PROGRESS" "$A_CLOSE"
run "launch then progress line" "$D/5.jsonl" SILENT

mk "$D/6.jsonl" "$A_LAUNCH_TASK" "$A_BASH_JOURNAL" "$A_CLOSE"
run "launch then journal.jsonl read" "$D/6.jsonl" SILENT

mk "$D/7.jsonl" "$A_LAUNCH_TASK" "$U_NOTIF" "$A_CLOSE"
run "launch then task-notification" "$D/7.jsonl" SILENT

mk "$D/8.jsonl" "$A_LAUNCH_TASK" "$U_RESULT" "$A_CLOSE"
run "launch then its tool_result" "$D/8.jsonl" SILENT

mk "$D/9.jsonl" "$A_BASH_FG" "$A_CLOSE"
run "no launch at all" "$D/9.jsonl" SILENT

mk "$D/10.jsonl" "$A_LAUNCH_TASK" "$A_MONITOR"
run "turn ends on a tool_use" "$D/10.jsonl" SILENT

# observation BEFORE the launch must not count
mk "$D/11.jsonl" "$A_MONITOR" "$A_LAUNCH_TASK" "$A_CLOSE"
run "observation precedes launch" "$D/11.jsonl" FIRE

# a second launch after an observed first one re-arms
mk "$D/12.jsonl" "$A_LAUNCH_TASK" "$A_MONITOR" "$A_LAUNCH_BG" "$A_CLOSE"
run "re-arm on later launch" "$D/12.jsonl" FIRE

# older notification must not clear a NEWER launch
mk "$D/13.jsonl" "$A_LAUNCH_TASK" "$U_NOTIF" "$A_LAUNCH_BG" "$A_CLOSE"
run "stale notification, newer launch" "$D/13.jsonl" FIRE

# robustness
mk "$D/14.jsonl" "not json at all" "$A_LAUNCH_TASK" "$A_CLOSE"
run "garbage line tolerated" "$D/14.jsonl" FIRE

mk "$D/15.jsonl" ""
run "empty transcript" "$D/15.jsonl" SILENT

out=$(printf '{"transcript_path":"/nonexistent/x.jsonl"}' | ruby "$HOOK" 2>&1); \
  [ -z "$out" ] && { pass=$((pass+1)); echo "ok   missing transcript                        SILENT"; } \
             || { fail=$((fail+1)); echo "FAIL missing transcript :: $out"; }
out=$(printf 'not-json' | ruby "$HOOK" 2>&1); \
  [ -z "$out" ] && { pass=$((pass+1)); echo "ok   malformed payload                         SILENT"; } \
             || { fail=$((fail+1)); echo "FAIL malformed payload :: $out"; }

echo "---- pass=$pass fail=$fail"
rm -rf "$D"
[ "$fail" -eq 0 ]
