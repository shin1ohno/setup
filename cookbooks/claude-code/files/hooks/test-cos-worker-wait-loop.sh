#!/usr/bin/env bash

# Tests the background wait loop and the Codex start step in the Chief of Staff
# dispatch reference. Each block is extracted from the document, so the text the
# controller follows is the text under test. A fake herdr plays the worker's
# states.
#
# The main case is a worker that writes its envelope while settled: no state
# transition happens, so a loop that only waits for transitions misses it.
#
# Usage: bash test-cos-worker-wait-loop.sh <path-to-dispatch.md>

set -uo pipefail
DOC="${1:?path to references/dispatch.md}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
pass=0; fail=0

awk '
  /^```bash$/ { buf = ""; inblock = 1; next }
  /^```$/ { if (inblock && buf ~ /reason=\$why/) { printf "%s", buf; exit } inblock = 0; next }
  inblock { buf = buf $0 "\n" }
' "$DOC" > "$D/loop.sh"

mkdir "$D/bin"
cat > "$D/bin/herdr" <<'FAKE'
#!/bin/bash
args=" $* "
case "$args" in
  *" agent get "*) [ ! -e "$WS/gone" ] || exit 1; [ -e "$WS/status" ] && cat "$WS/status"; exit 0 ;;
  *" agent wait "*)
    case "$args" in *" --until blocked "*) ;; *) echo "unexpected wait: $args" >> "$WS/bad" ;; esac
    if [ -e "$WS/blocked" ]; then exit 0; fi
    sleep 0.1
    exit 1 ;;
  *) echo "unexpected call: $args" >> "$WS/bad"; exit 2 ;;
esac
FAKE
chmod +x "$D/bin/herdr"

check() { # check <name> <0|1> [detail]
  if [ "$2" = 0 ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$1"
  else
    fail=$((fail+1)); printf 'FAIL %s :: %s\n' "$1" "${3:-}"
  fi
}

N=0
run() { # run <loop-file> ; sets WS first, then OUT and ELAPSED
  local started=$SECONDS
  OUT=$(WS=$WS s=test-session worker=w1 envelope="$WS/envelope-1.json" PATH="$D/bin:$PATH" \
    timeout 20 bash "$1" 2>&1)
  ELAPSED=$((SECONDS-started))
}

new_ws() { N=$((N+1)); WS="$D/ws$N"; mkdir "$WS"; }

expect() { # expect <name> <reason> <max-seconds>
  local bad=""
  [ -e "$WS/bad" ] && bad=$(cat "$WS/bad")
  [ "$OUT" = "reason=$2" ] && [ "$ELAPSED" -le "$3" ] && [ -z "$bad" ]
  check "$1" $? "out=$OUT elapsed=$ELAPSED bad=$bad"
}

grep -q 'SECONDS+600' "$D/loop.sh"; check "the wait is bounded at ten minutes" $?
grep -q -- '--until blocked --timeout 15000' "$D/loop.sh"; check "each blocked wait is short" $?

new_ws; echo '{}' > "$WS/envelope-1.json"
run "$D/loop.sh"
expect "envelope already present" envelope 3

# The review's race: the worker is settled, no transition ever comes, and the
# envelope appears while the loop is inside a wait.
new_ws
( sleep 1; echo '{}' > "$WS/envelope-1.json" ) &
run "$D/loop.sh"
wait
expect "envelope written while the worker stays settled" envelope 5

new_ws; touch "$WS/blocked"
run "$D/loop.sh"
expect "worker at a dialog" blocked 3

new_ws; touch "$WS/gone"
run "$D/loop.sh"
expect "worker gone" gone 3

new_ws
( sleep 1; touch "$WS/gone" ) &
run "$D/loop.sh"
wait
expect "worker disappears during the wait" gone 5

new_ws
( sleep 1; touch "$WS/blocked" ) &
run "$D/loop.sh"
wait
expect "worker reaches a dialog during the wait" blocked 5

# The ten minutes are shortened here only; the documented value is checked above.
sed 's/SECONDS+600/SECONDS+2/' "$D/loop.sh" > "$D/short.sh"
new_ws
run "$D/short.sh"
expect "nothing happens until the limit" timeout 6

new_ws; mkdir "$WS/envelope-1.json"
run "$D/short.sh"
expect "a directory is not an envelope" timeout 6

# Silent stop: idle with no envelope for three checks. The 15 s spacing is shortened
# here only; the documented value is checked first.
grep -q 'sleep 15' "$D/loop.sh"; check "idle checks are spaced" $?
grep -q -- '-ge 3' "$D/loop.sh"; check "idle needs three checks" $?
sed 's/sleep 15/sleep 0.2/' "$D/loop.sh" > "$D/fast.sh"
IDLE='{"result":{"agent":{"agent_status":"idle"}}}'
WORKING='{"result":{"agent":{"agent_status":"working"}}}'
DONE='{"result":{"agent":{"agent_status":"done"}}}'

new_ws; echo "$IDLE" > "$WS/status"
run "$D/fast.sh"
expect "idle with no envelope ends as idle" idle 10

new_ws; echo "$WORKING" > "$WS/status"
run "$D/short.sh"
expect "a working agent is not idle" timeout 6

new_ws; echo "$DONE" > "$WS/status"
run "$D/short.sh"
expect "a done agent (own background job) is not idle" timeout 6

new_ws; echo "$IDLE" > "$WS/status"
( sleep 0.2; echo '{}' > "$WS/envelope-1.json" ) &
run "$D/fast.sh"
wait
expect "an envelope still wins while idle" envelope 10

new_ws; echo "$IDLE" > "$WS/status"; touch "$WS/blocked"
run "$D/fast.sh"
expect "blocked wins over idle" blocked 5

# Each detection, removed, must change the result.
grep -v -- '-ge 3' "$D/fast.sh" | sed 's/SECONDS+600/SECONDS+3/' > "$D/mut1.sh"
new_ws; echo "$IDLE" > "$WS/status"
run "$D/mut1.sh"
[ "$OUT" != "reason=idle" ]; check "without the idle exit the idle case fails" $? "out=$OUT"
sed 's/\*.*agent_status.*idle.*) idle=\$((idle+1)) ;;/*) idle=0 ;;/' "$D/fast.sh" | sed 's/SECONDS+600/SECONDS+3/' > "$D/mut2.sh"
cmp -s "$D/fast.sh" "$D/mut2.sh" && check "mutant 2 differs from the loop" 1 "sed did not match"
new_ws; echo "$IDLE" > "$WS/status"
run "$D/mut2.sh"
[ "$OUT" != "reason=idle" ]; check "without the idle count the idle case fails" $? "out=$OUT"

# --- the Codex start step -----------------------------------------------------

awk '
  /^```bash$/ { buf = ""; inblock = 1; next }
  /^```$/ { if (inblock && buf ~ /agent rename/) { printf "%s", buf; exit } inblock = 0; next }
  inblock { buf = buf $0 "\n" }
' "$DOC" > "$D/start.sh"
sed 's/seq 1 30/seq 1 3/' "$D/start.sh" > "$D/start-short.sh"

mkdir "$D/cbin"
cat > "$D/cbin/herdr" <<'FAKE'
#!/bin/bash
# Files in $WS: named (the name resolves), renamable (rename restores it),
# start-err (agent start fails with its content), waits (one result per wait).
printf '%s\n' "$*" >> "$WS/calls"
args=" $* "
case "$args" in
  *" pane read "*)
    n=$(( $(cat "$WS/pn" 2>/dev/null || echo 0) + 1 )); echo $n > "$WS/pn"
    [ -e "$WS/pane" ] && sed -n "${n}p" "$WS/pane"; exit 0 ;;
  *" agent start "*)
    if [ -e "$WS/busy" ]; then
      k=$(( $(cat "$WS/bn" 2>/dev/null || echo 0) + 1 )); echo $k > "$WS/bn"
      [ "$k" -le "$(cat "$WS/busy")" ] && { echo '{"error":{"code":"agent_pane_busy"}}' >&2; exit 1; }
    fi
    [ -e "$WS/start-err" ] && { cat "$WS/start-err" >&2; exit 1; }; touch "$WS/named"; exit 0 ;;
  *" agent get "*) [ -e "$WS/named" ] ;;
  *" agent rename "*) [ -e "$WS/renamable" ] && { touch "$WS/named"; exit 0; }; exit 1 ;;
  *" agent wait "*)
    n=$(( $(cat "$WS/n" 2>/dev/null || echo 0) + 1 )); echo $n > "$WS/n"
    case "$(sed -n "${n}p" "$WS/waits")" in
      working) echo '{"result":{"agent":{"agent_status":"working"}}}' ;;
      blocked) echo '{"result":{"agent":{"agent_status":"blocked"}}}' ;;
      not_found) rm -f "$WS/named"; echo '{"error":{"code":"agent_not_found"}}' >&2; exit 1 ;;
      timeout) echo '{"error":{"code":"timeout"}}' >&2; exit 1 ;;
      *) exit 9 ;;
    esac ;;
  *) exit 2 ;;
esac
FAKE
chmod +x "$D/cbin/herdr"

start() { # start <file> <name> <want-exit> <want-status|-> <want-renames>
  local f=$1 name=$2 want=$3 status=$4 renames=$5 got out n
  out=$(WS=$WS s=test-session worker=cx pane=w1:pB kind=${TEST_KIND:-codex} unset_cmd=${UNSET:-} TMPDIR=$WS model=m effort=low launch_prompt=go \
    PATH="$D/cbin:$PATH" timeout 20 bash "$f" 2>/dev/null)
  got=$?
  n=$(grep -c ' agent rename w1:pB cx$' "$WS/calls")
  if [ "$got" = "$want" ] && [ "$n" = "$renames" ] &&
     { [ "$status" = - ] || printf '%s' "$out" | grep -q "\"agent_status\":\"$status\""; }; then
    check "$name" 0
  else
    check "$name" 1 "exit=$got renames=$n out=$out calls=$(tr '\n' ';' < "$WS/calls")"
  fi
}

new_ws; printf '%s\n' working > "$WS/waits"
start "$D/start.sh" "start succeeds: working observed, no rename" 0 working 0

new_ws; printf '%s\n' blocked > "$WS/waits"
start "$D/start.sh" "start succeeds: blocked observed" 0 blocked 0

new_ws; echo timeout > "$WS/start-err"; touch "$WS/named"; printf '%s\n' working > "$WS/waits"
start "$D/start.sh" "start times out, the name holds, working observed" 0 working 0

new_ws; echo agent_name_not_found > "$WS/start-err"; touch "$WS/renamable"; printf '%s\n' working > "$WS/waits"
start "$D/start.sh" "start loses the name: restored through the pane" 0 working 1

new_ws; touch "$WS/named" "$WS/renamable"; printf '%s\n' not_found working > "$WS/waits"
start "$D/start.sh" "the wait returns agent_not_found: renamed and re-checked" 0 working 1

new_ws; echo timeout > "$WS/start-err"; touch "$WS/named"; printf '%s\n' timeout > "$WS/waits"
start "$D/start.sh" "the wait times out: non-zero even though start was tolerated" 1 - 0
[ "$(cat "$WS/n")" = 1 ]; check "a wait timeout is not retried" $? "waits=$(cat "$WS/n")"

new_ws; echo agent_name_not_found > "$WS/start-err"; : > "$WS/waits"
start "$D/start-short.sh" "the name never returns: bounded, non-zero" 1 - 3

# The pane prompt wait and the agent_pane_busy retry (2026-11-14).
starts() { grep -c ' agent start ' "$WS/calls"; }
reads() { grep -c ' pane read ' "$WS/calls"; }

new_ws; printf '%s\n' '$ unset FOO' '$ unset FOO' 'prompt >' > "$WS/pane"; printf '%s\n' working > "$WS/waits"
UNSET='unset FOO' start "$D/start.sh" "start waits until a prompt follows the unset line" 0 working 0
[ "$(reads)" = 3 ]; check "the pane was read until the prompt returned" $? "reads=$(reads)"
grep -n ' pane read ' "$WS/calls" | tail -1 | cut -d: -f1 > "$WS/lr"
[ "$(grep -n ' agent start ' "$WS/calls" | head -1 | cut -d: -f1)" -gt "$(cat "$WS/lr")" ]; check "agent start comes after the prompt" $?

new_ws; printf '%s\n' working > "$WS/waits"
start "$D/start.sh" "without unset_cmd the pane is not read" 0 working 0
[ "$(reads)" = 0 ]; check "no pane read without unset_cmd" $? "reads=$(reads)"

new_ws; echo 1 > "$WS/busy"; printf '%s\n' working > "$WS/waits"
start "$D/start.sh" "agent_pane_busy once: retried and started" 0 working 0
[ "$(starts)" = 2 ]; check "start was retried exactly once" $? "starts=$(starts)"

new_ws; echo 5 > "$WS/busy"; : > "$WS/waits"
start "$D/start-short.sh" "agent_pane_busy twice: no third start" 1 - 3
[ "$(starts)" = 2 ]; check "busy start is retried only once" $? "starts=$(starts)"

new_ws; echo timeout > "$WS/start-err"; touch "$WS/named"; printf '%s\n' working > "$WS/waits"
start "$D/start.sh" "another start error is not retried" 0 working 0
[ "$(starts)" = 1 ]; check "only agent_pane_busy is retried" $? "starts=$(starts)"

sed 's/agent_pane_busy/never_matches/' "$D/start.sh" > "$D/start-mut.sh"
new_ws; echo 1 > "$WS/busy"; : > "$WS/waits"
[ "$(WS=$WS s=t worker=cx pane=w1:pB kind=codex model=m effort=low launch_prompt=go TMPDIR=$WS PATH="$D/cbin:$PATH" timeout 20 bash "$D/start-mut.sh" >/dev/null 2>&1; echo $?)" != 0 ]
check "without the busy retry the start fails" $?

printf '\npassed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" = 0 ]
