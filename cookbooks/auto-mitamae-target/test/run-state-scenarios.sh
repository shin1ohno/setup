#!/bin/bash
# Hermetic regression harness for the auto-mitamae per-SHA apply state
# (ADR 0009). Runs the PRODUCTION scripts unmodified —
#   cookbooks/auto-mitamae-target/files/mitamae-runner.sh
#   cookbooks/auto-mitamae-orchestrator/files/orchestrator.sh
# — with their paths redirected into a throwaway tmpdir via the
# AUTO_MITAMAE_* / AUTO_MITAMAE_ORCH_* env hooks, a local bare git origin,
# a `bin/mitamae` stand-in whose verdict is a control file, and an `ssh`
# stand-in on PATH that replays canned runner answers per host. No network,
# no real hosts, no root.
#
# Scenarios (the handoff's acceptance list, verbatim):
#   1. A success → B fails → the SAME B is retried next cycle (not up_to_date)
#      → B succeeds → subsequent cycles are up_to_date
#   2. A periodic re-apply of the same SHA fails → retried next cycle
#   3. Canary ssh_unreachable / lock_held / sha_mismatch / unverified
#      up_to_date / mitamae_fail → fleet host is NOT contacted;
#      success / verified up_to_date → fleet host IS contacted
#   4. A verified same-SHA host is NOT re-applied inside the reconcile window
#      (mitamae call count stays flat = the ADR 0006 load throttle survives)
#
# Exit 0 when every assertion passes; non-zero otherwise. Output is one
# PASS/FAIL line per assertion plus a final summary — paste it into the PR.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
# SCENARIO_RUNNER / SCENARIO_ORCH point the harness at another copy of the
# scripts — used as the positive control: against the pre-ADR-0009 scripts
# (`git show <old>:cookbooks/.../mitamae-runner.sh`) the harness MUST fail.
RUNNER="${SCENARIO_RUNNER:-$REPO/cookbooks/auto-mitamae-target/files/mitamae-runner.sh}"
ORCH="${SCENARIO_ORCH:-$REPO/cookbooks/auto-mitamae-orchestrator/files/orchestrator.sh}"

T=$(mktemp -d "${TMPDIR:-/tmp}/auto-mitamae-scenarios.XXXXXX")
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "PASS  $*"; }
bad()  { fail=$((fail+1)); echo "FAIL  $*"; }
assert_eq() { # label expected actual
    if [[ "$2" == "$3" ]]; then ok "$1 (= $2)"; else bad "$1: expected [$2] got [$3]"; fi
}

# ---------------------------------------------------------------- fixtures
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

CALLS="$T/mitamae-calls.log"; : > "$CALLS"
VERDICT="$T/mitamae-verdict"; echo success > "$VERDICT"

git init -q -b main "$T/src"
mkdir -p "$T/src/bin"
cat > "$T/src/bin/mitamae" <<STUB
#!/bin/bash
# stand-in: append the invocation, exit per the control file.
# kill-parent simulates the runner dying mid-apply (reboot / OOM / ^C).
echo "\$*" >> "$CALLS"
v=\$(cat "$VERDICT")
if [[ "\$v" == kill-parent ]]; then kill -9 \$PPID; exit 1; fi
[[ "\$v" == success ]]
STUB
chmod +x "$T/src/bin/mitamae"
echo a > "$T/src/a.txt"
git -C "$T/src" add -A && git -C "$T/src" commit -qm A
SHA_A=$(git -C "$T/src" rev-parse HEAD)
git clone -q --bare "$T/src" "$T/origin.git"
git -C "$T/src" remote add origin "$T/origin.git"
git clone -q "$T/origin.git" "$T/target"
git -C "$T/target" checkout -q "$SHA_A"

export AUTO_MITAMAE_SETUP_DIR="$T/target"
export AUTO_MITAMAE_STATE_DIR="$T/state"
export AUTO_MITAMAE_LOCK_FILE="$T/runner.lock"
export AUTO_MITAMAE_APPLY_LOG="$T/apply.log"
ROLE="pve/lxc-test.rb"

run_runner() { # sha -> prints status line; exit code lands in $T/rc
    local out
    out=$(SSH_ORIGINAL_COMMAND="$ROLE $1" bash "$RUNNER" 2>"$T/runner.err"); echo $? > "$T/rc"
    echo "$out"
}
rc_last() { cat "$T/rc"; }
status_of() { grep -oE 'status=[a-z_]+' <<<"$1" | head -1 | cut -d= -f2; }
calls() { wc -l < "$CALLS" | tr -d ' '; }

# ---------------------------------------------------------------- scenario 1
echo "== scenario 1: A success → B fails → B retried → B succeeds → up_to_date"
out=$(run_runner "$SHA_A")
assert_eq "s1 initial A" success "$(status_of "$out")"
assert_eq "s1 mitamae calls after A" 1 "$(calls)"

echo b > "$T/src/b.txt"; git -C "$T/src" add -A; git -C "$T/src" commit -qm B
git -C "$T/src" push -q origin main
SHA_B=$(git -C "$T/src" rev-parse HEAD)

echo fail > "$VERDICT"
out=$(run_runner "$SHA_B")
assert_eq "s1 first B" mitamae_fail "$(status_of "$out")"
assert_eq "s1 first B exit" 1 "$(rc_last)"
assert_eq "s1 mitamae calls after first B" 2 "$(calls)"
assert_eq "s1 HEAD is B after failed apply (drift now 0)" "$SHA_B" "$(git -C "$T/target" rev-parse HEAD)"

out=$(run_runner "$SHA_B")
assert_eq "s1 SAME B next cycle is retried, not up_to_date" mitamae_fail "$(status_of "$out")"
assert_eq "s1 mitamae calls after retry" 3 "$(calls)"

echo success > "$VERDICT"
out=$(run_runner "$SHA_B")
assert_eq "s1 B eventually succeeds" success "$(status_of "$out")"
assert_eq "s1 success line carries verified_sha=B" "$SHA_B" "$(grep -oE 'verified_sha=[a-f0-9]+' <<<"$out" | cut -d= -f2)"
assert_eq "s1 state names B" "last_success_sha=$SHA_B" "$(grep ^last_success_sha= "$T/state/apply-state")"

out=$(run_runner "$SHA_B")
assert_eq "s1 verified B is now up_to_date" up_to_date "$(status_of "$out")"
assert_eq "s1 up_to_date carries verified_sha=B" "$SHA_B" "$(grep -oE 'verified_sha=[a-f0-9]+' <<<"$out" | cut -d= -f2)"
assert_eq "s1 mitamae calls unchanged by up_to_date" 4 "$(calls)"

# ---------------------------------------------------------------- scenario 2
echo "== scenario 2: same-SHA periodic reconcile fails → retried next cycle"
echo fail > "$VERDICT"
out=$(AUTO_MITAMAE_RECONCILE_INTERVAL_SEC=0 AUTO_MITAMAE_RECONCILE_JITTER_SEC=0 run_runner "$SHA_B")
assert_eq "s2 forced reconcile of B fails" mitamae_fail "$(status_of "$out")"
assert_eq "s2 state still names B as last success" "last_success_sha=$SHA_B" "$(grep ^last_success_sha= "$T/state/apply-state")"
assert_eq "s2 state records failed attempt" "last_attempt_status=mitamae_fail" "$(grep ^last_attempt_status= "$T/state/apply-state")"
out=$(run_runner "$SHA_B")   # default 1h window would have throttled on the old stamp
assert_eq "s2 next cycle retries despite fresh success timestamp" mitamae_fail "$(status_of "$out")"
echo success > "$VERDICT"
out=$(run_runner "$SHA_B")
assert_eq "s2 recovers to success" success "$(status_of "$out")"
out=$(run_runner "$SHA_B")
assert_eq "s2 then throttles again" up_to_date "$(status_of "$out")"

# ---------------------------------------------------------------- scenario 4
echo "== scenario 4: verified same SHA is not re-applied inside the window"
before=$(calls)
for _ in 1 2 3 4 5; do out=$(run_runner "$SHA_B"); assert_eq "s4 cycle up_to_date" up_to_date "$(status_of "$out")"; done
assert_eq "s4 mitamae calls flat across 5 cycles" "$before" "$(calls)"
# state sanity: corrupt file → converge, never abort before the status line
printf 'last_success_sha=garbage\nlast_success_epoch=notanumber\n' > "$T/state/apply-state"
out=$(run_runner "$SHA_B")
assert_eq "s4 corrupt state converges (no silent ssh_unreachable)" success "$(status_of "$out")"
# legacy stamp alone must not suppress
rm -f "$T/state/apply-state"; date +%s > "$T/state/last-converge.epoch"
out=$(run_runner "$SHA_B")
assert_eq "s4 legacy timestamp-only stamp does not suppress" success "$(status_of "$out")"
[[ -f "$T/state/last-converge.epoch" ]] && bad "s4 legacy stamp removed on success" || ok "s4 legacy stamp removed on success"
# lock held → lock_held, no apply
before=$(calls)
out=$( exec 9>"$T/runner.lock"; flock -n 9; SSH_ORIGINAL_COMMAND="$ROLE $SHA_B" bash "$RUNNER" 2>/dev/null )
assert_eq "s4 lock_held while flock taken" lock_held "$(status_of "$out")"
assert_eq "s4 lock_held did not apply" "$before" "$(calls)"

# review F2: same SHA, different role → the old role's proof must not apply
echo success > "$VERDICT"
out=$(run_runner "$SHA_B"); assert_eq "s4/F2 baseline verified for role A" up_to_date "$(status_of "$out")"
before=$(calls)
out=$(ROLE="pve/lxc-other.rb" run_runner "$SHA_B")
assert_eq "s4/F2 role change on same SHA converges" success "$(status_of "$out")"
assert_eq "s4/F2 role change ran mitamae" $((before+1)) "$(calls)"
assert_eq "s4/F2 state names new role" "last_success_role=pve/lxc-other.rb" "$(grep ^last_success_role= "$T/state/apply-state")"
out=$(run_runner "$SHA_B")
assert_eq "s4/F2 switching back also converges (single proof per host)" success "$(status_of "$out")"

# review F3: interrupted apply → in_progress written before mitamae; next cycle converges
echo kill-parent > "$VERDICT"
# force a reconcile (host is verified + inside the window) so mitamae actually runs;
# the stub then kills the runner mid-apply → no final state write
out=$(AUTO_MITAMAE_RECONCILE_INTERVAL_SEC=0 AUTO_MITAMAE_RECONCILE_JITTER_SEC=0 run_runner "$SHA_B")
assert_eq "s4/F3 interrupted apply produced no status line" "" "$(status_of "$out")"
assert_eq "s4/F3 state shows in_progress" "last_attempt_status=in_progress" "$(grep ^last_attempt_status= "$T/state/apply-state")"
assert_eq "s4/F3 proof of the old success is still on record" "last_success_sha=$SHA_B" "$(grep ^last_success_sha= "$T/state/apply-state")"
echo success > "$VERDICT"
out=$(run_runner "$SHA_B")
assert_eq "s4/F3 next cycle converges instead of trusting the old proof" success "$(status_of "$out")"
out=$(run_runner "$SHA_B")
assert_eq "s4/F3 then verified again" up_to_date "$(status_of "$out")"

# review D2: reader robustness — no trailing newline, duplicate key, octal-looking epoch
printf 'last_success_sha=%s\nlast_success_role=%s\nlast_success_epoch=%s\nlast_attempt_sha=%s\nlast_attempt_status=success\nlast_attempt_epoch=1\nlast_attempt_status=mitamae_fail' "$SHA_B" "$ROLE" "$(date +%s)" "$SHA_B" > "$T/state/apply-state"
out=$(run_runner "$SHA_B")
assert_eq "s4/D2 duplicate key + no trailing newline → converge, not up_to_date" success "$(status_of "$out")"
printf 'last_success_sha=%s\nlast_success_role=%s\nlast_success_epoch=09\nlast_attempt_sha=%s\nlast_attempt_status=success\nlast_attempt_epoch=1\n' "$SHA_B" "$ROLE" "$SHA_B" > "$T/state/apply-state"
out=$(run_runner "$SHA_B")
assert_eq "s4/D2 epoch 09 (octal trap) → converges with a status line" success "$(status_of "$out")"

# review D3: state write failure must answer state_write_fail, not die silently
mkdir -p "$T/badbin"; printf '#!/bin/bash\nexit 1\n' > "$T/badbin/mktemp"; chmod +x "$T/badbin/mktemp"
before=$(calls)
out=$(PATH="$T/badbin:$PATH" AUTO_MITAMAE_RECONCILE_INTERVAL_SEC=0 AUTO_MITAMAE_RECONCILE_JITTER_SEC=0 run_runner "$SHA_B")
assert_eq "s4/D3 mktemp failure → status=state_write_fail" state_write_fail "$(status_of "$out")"
assert_eq "s4/D3 state write failure before apply → mitamae not called" "$before" "$(calls)"
assert_eq "s4/D3 state_write_fail exits 1" 1 "$(rc_last)"

# review D8: overrides are ignored inside an ssh session (SSH_CONNECTION set)
before=$(calls)
out=$(SSH_CONNECTION="10.0.0.1 1 10.0.0.2 22" run_runner "$SHA_B")
assert_eq "s4/D8 SSH_CONNECTION set → harness paths ignored (no apply in the fixture)" "$before" "$(calls)"
[[ "$(status_of "$out")" != up_to_date && "$(status_of "$out")" != success ]] && ok "s4/D8 ssh-session run did not report a fixture verdict (= $(status_of "$out"))" || bad "s4/D8 ssh-session run used the fixture paths"

# ---------------------------------------------------------------- scenario 3
echo "== scenario 3: orchestrator canary gate — hold on unverified, pass on verified"
O="$T/orch"; mkdir -p "$O/textfile" "$O/bin"
CONTACT="$O/contacted.log"
CANARY_REPLY="$O/canary.invalid.reply"   # must match the ssh stub: <host>.reply
# ssh stand-in: the LAST argv is "<role> <sha>"; the host is the "user@host"
# argv before it. Replies come from a per-host file; missing file = ssh error
# with no status line (→ ssh_unreachable in the orchestrator).
cat > "$O/bin/ssh" <<'STUB'
#!/bin/bash
host=""
for a in "$@"; do case "$a" in *@*) host="$a";; esac; done
echo "$host" >> "$ORCH_CONTACT_LOG"
f="$ORCH_REPLY_DIR/${host#*@}.reply"
[[ -f "$ORCH_REPLY_DIR/${host#*@}.sleep" ]] && sleep 3
if [[ -f "$f" ]]; then cat "$f"; exit "$(cat "$f.rc" 2>/dev/null || echo 0)"; fi
echo "ssh: connect to host ${host#*@}: No route to host" >&2
exit 255
STUB
chmod +x "$O/bin/ssh"
export ORCH_CONTACT_LOG="$CONTACT" ORCH_REPLY_DIR="$O"
cat > "$O/hosts.json" <<JSON
[
  {"host": "canary.invalid", "user": "root", "role": "pve/lxc-canary.rb", "label": "canary", "ct_id": 1, "canary": true},
  {"host": "fleet.invalid",  "user": "root", "role": "pve/lxc-fleet.rb",  "label": "fleet",  "ct_id": 2}
]
JSON
EXP="$SHA_B"
printf 'setup_main_head_commit_info{commit="%s"} 1\nsetup_main_head_check_status{result="ok"} 1\n' "$EXP" > "$O/textfile/drift-checker.prom"
echo "status=success sha=$EXP drift=0 duration=1 old=$EXP verified_sha=$EXP ts=now" > "$O/fleet.invalid.reply"

run_orch() { # canary reply text (empty = unreachable), rc
    : > "$CONTACT"
    if [[ -n "$1" ]]; then echo "$1" > "$CANARY_REPLY"; echo "${2:-0}" > "$CANARY_REPLY.rc"; else rm -f "$CANARY_REPLY" "$CANARY_REPLY.rc"; fi
    PATH="$O/bin:$PATH" \
    AUTO_MITAMAE_ORCH_LOCK_FILE="$O/orch.lock" \
    AUTO_MITAMAE_ORCH_TEXTFILE_DIR="$O/textfile" \
    AUTO_MITAMAE_ORCH_HOSTS_JSON="$O/hosts.json" \
    AUTO_MITAMAE_ORCH_SSH_KEY="$O/nokey" \
    AUTO_MITAMAE_ORCH_SSH_KNOWN_HOSTS="$O/known" \
        bash "$ORCH" >"$O/orch.out" 2>"$O/orch.err"
    ORC=$?
}
fleet_contacted() { grep -c 'fleet.invalid' "$CONTACT" | tr -d ' '; }
gate() { grep -oE 'auto_mitamae_canary_gate\{result="[a-z]+"\}' "$O/textfile/auto-mitamae.prom" | cut -d'"' -f2; }
cstatus() { grep -oE 'auto_mitamae_canary_last_status\{result="[a-z_]+"\}' "$O/textfile/auto-mitamae.prom" | cut -d'"' -f2; }

run_orch ""                                                       # ssh error, no status line
assert_eq "s3 unreachable canary → fleet not contacted" 0 "$(fleet_contacted)"
assert_eq "s3 unreachable → gate hold" hold "$(gate)"
assert_eq "s3 unreachable → raw status kept" ssh_unreachable "$(cstatus)"
assert_eq "s3 unreachable → exit 0 (retry next cron)" 0 "$ORC"

run_orch "status=lock_held ts=now" 0
assert_eq "s3 lock_held canary → fleet not contacted" 0 "$(fleet_contacted)"
assert_eq "s3 lock_held → gate hold" hold "$(gate)"
assert_eq "s3 lock_held → raw status kept" lock_held "$(cstatus)"

run_orch "status=sha_mismatch expected=$EXP actual=$SHA_A old=$SHA_A ts=now" 1
assert_eq "s3 sha_mismatch canary → fleet not contacted" 0 "$(fleet_contacted)"
assert_eq "s3 sha_mismatch → gate hold" hold "$(gate)"
assert_eq "s3 sha_mismatch → raw status kept" sha_mismatch "$(cstatus)"

run_orch "status=up_to_date sha=$EXP drift=0 duration=0 old=$EXP ts=now" 0   # pre-0009 runner shape
assert_eq "s3 up_to_date WITHOUT verified_sha → fleet not contacted" 0 "$(fleet_contacted)"
assert_eq "s3 unverified up_to_date → gate hold" hold "$(gate)"
assert_eq "s3 unverified up_to_date → raw status kept" up_to_date "$(cstatus)"

run_orch "status=up_to_date sha=$EXP drift=0 duration=0 old=$EXP verified_sha=$SHA_A ts=now" 0
assert_eq "s3 up_to_date verified for ANOTHER sha → fleet not contacted" 0 "$(fleet_contacted)"
assert_eq "s3 up_to_date verified for ANOTHER sha → raw status kept" up_to_date "$(cstatus)"

run_orch "status=mitamae_fail sha=$EXP drift=1 duration=3 old=$SHA_A ts=now" 1
assert_eq "s3 mitamae_fail canary → fleet not contacted" 0 "$(fleet_contacted)"
assert_eq "s3 mitamae_fail → gate fail" fail "$(gate)"
assert_eq "s3 mitamae_fail → raw status for AutoMitamaeCanaryFailing" mitamae_fail "$(cstatus)"

run_orch "status=up_to_date sha=$EXP drift=0 duration=0 old=$EXP verified_sha=$EXP ts=now" 0
assert_eq "s3 verified up_to_date → fleet contacted" 1 "$(fleet_contacted)"
assert_eq "s3 verified up_to_date → gate pass" pass "$(gate)"

run_orch "status=success sha=$EXP drift=1 duration=4 old=$SHA_A verified_sha=$EXP ts=now" 0
assert_eq "s3 success → fleet contacted" 1 "$(fleet_contacted)"
assert_eq "s3 success → gate pass" pass "$(gate)"
assert_eq "s3 success → cycle complete" "orchestrator: cycle complete at expected_sha=$EXP" "$(cat "$O/orch.out")"

run_orch "status=success sha=$SHA_A drift=1 duration=4 old=$SHA_A verified_sha=$SHA_A ts=now" 0
assert_eq "s3 success for a DIFFERENT sha → fleet not contacted" 0 "$(fleet_contacted)"
assert_eq "s3 success for a different sha → gate hold" hold "$(gate)"

run_orch "status=bogus_state ts=now" 0
assert_eq "s3 unknown status → fleet not contacted" 0 "$(fleet_contacted)"
assert_eq "s3 unknown status → gate hold" hold "$(gate)"

# review F6: gate series survives a hold→(next cycle) mid-cycle publish window
run_orch "status=lock_held ts=now" 0
assert_eq "s3/F6 gate line present after hold" 1 "$(grep -c '^auto_mitamae_canary_gate{' "$O/textfile/auto-mitamae.prom")"

# review F1: hosts.json validation — zero canary / malformed → refuse the cycle, contact nobody
cp "$O/hosts.json" "$O/hosts.json.bak"
cat > "$O/hosts.json" <<JSON
[ {"host": "fleet.invalid", "user": "root", "role": "pve/lxc-fleet.rb", "label": "fleet", "ct_id": 2} ]
JSON
run_orch "status=success sha=$EXP drift=1 duration=4 old=$SHA_A verified_sha=$EXP ts=now" 0
assert_eq "s3/F1 zero-canary hosts.json → nobody contacted" 0 "$(wc -l < "$CONTACT" | tr -d ' ')"
assert_eq "s3/F1 zero-canary hosts.json → cycle refused (exit 1)" 1 "$ORC"
echo '[ {"host": "canary.invalid", "user": "root", "role": "pve/lxc-canary.rb", "label": "canary", "canary": true' > "$O/hosts.json"
run_orch "status=success sha=$EXP drift=1 duration=4 old=$SHA_A verified_sha=$EXP ts=now" 0
assert_eq "s3/F1 malformed hosts.json → nobody contacted" 0 "$(wc -l < "$CONTACT" | tr -d ' ')"
assert_eq "s3/F1 malformed hosts.json → cycle refused (exit 1)" 1 "$ORC"
mv "$O/hosts.json.bak" "$O/hosts.json"

# multi-canary aggregation: fail beats hold beats pass
cat > "$O/hosts.json" <<JSON
[
  {"host": "canary.invalid",  "user": "root", "role": "pve/lxc-canary.rb",  "label": "canary",  "canary": true},
  {"host": "canary2.invalid", "user": "root", "role": "pve/lxc-canary2.rb", "label": "canary2", "canary": true},
  {"host": "fleet.invalid",   "user": "root", "role": "pve/lxc-fleet.rb",   "label": "fleet"}
]
JSON
echo "status=success sha=$EXP drift=1 duration=4 old=$SHA_A verified_sha=$EXP ts=now" > "$O/canary2.invalid.reply"
run_orch "status=lock_held ts=now" 0
assert_eq "s3 multi-canary pass+hold → fleet not contacted" 0 "$(fleet_contacted)"
assert_eq "s3 multi-canary pass+hold → gate hold" hold "$(gate)"
run_orch "status=mitamae_fail sha=$EXP drift=1 duration=3 old=$SHA_A ts=now" 1
assert_eq "s3 multi-canary pass+fail → gate fail" fail "$(gate)"
run_orch "status=success sha=$EXP drift=1 duration=4 old=$SHA_A verified_sha=$EXP ts=now" 0
assert_eq "s3 multi-canary pass+pass → fleet contacted" 1 "$(fleet_contacted)"
assert_eq "s3 multi-canary pass+pass → gate pass" pass "$(gate)"

# review D1: malformed answers must never pass the gate
run_orch "status=up_to_date not_verified_sha=$EXP ts=now" 0
assert_eq "s3/D1 not_verified_sha= key → fleet not contacted" 0 "$(fleet_contacted)"
run_orch "status=success sha=${EXP}z drift=1 duration=1 old=$SHA_A ts=now" 0
assert_eq "s3/D1 success with non-hex sha suffix → fleet not contacted" 0 "$(fleet_contacted)"
run_orch "status=success sha=$EXP sha=$SHA_A drift=1 duration=1 old=$SHA_A verified_sha=$EXP ts=now" 0
assert_eq "s3/D1 duplicated sha key → fleet not contacted" 0 "$(fleet_contacted)"
run_orch "status=state_write_fail sha=$EXP drift=1 duration=1 old=$SHA_A ts=now" 1
assert_eq "s3/D3 state_write_fail canary → gate hold" hold "$(gate)"

# review D6: the previous verdict stays published while a later canary is still being applied
echo "status=success sha=$EXP drift=1 duration=4 old=$SHA_A verified_sha=$EXP ts=now" > "$O/canary2.invalid.reply"
run_orch "status=lock_held ts=now" 0     # leaves gate=hold in the published file
touch "$O/canary2.invalid.sleep"          # stub sleeps 3s before answering for canary2
( : > "$CONTACT"; echo "status=success sha=$EXP drift=1 duration=4 old=$SHA_A verified_sha=$EXP ts=now" > "$CANARY_REPLY"; echo 0 > "$CANARY_REPLY.rc"
  PATH="$O/bin:$PATH" AUTO_MITAMAE_ORCH_LOCK_FILE="$O/orch.lock" AUTO_MITAMAE_ORCH_TEXTFILE_DIR="$O/textfile" AUTO_MITAMAE_ORCH_HOSTS_JSON="$O/hosts.json" AUTO_MITAMAE_ORCH_SSH_KEY="$O/nokey" AUTO_MITAMAE_ORCH_SSH_KNOWN_HOSTS="$O/known" bash "$ORCH" >"$O/orch.out" 2>"$O/orch.err" ) &
opid=$!
for _ in $(seq 1 40); do grep -q canary2.invalid "$CONTACT" 2>/dev/null && break; sleep 0.1; done
sleep 0.3   # canary1's publish has happened; canary2 is inside its 3s sleep
midgate=$(gate); midts=$(grep -c '^auto_mitamae_canary_gate_timestamp_seconds' "$O/textfile/auto-mitamae.prom")
wait "$opid"
assert_eq "s3/D6 mid-cycle publish still carries the previous verdict" hold "$midgate"
assert_eq "s3/D6 mid-cycle publish carries exactly one gate timestamp" 1 "$midts"
assert_eq "s3/D6 final verdict replaces it" pass "$(gate)"
assert_eq "s3/D6 final file has one gate line" 1 "$(grep -c '^auto_mitamae_canary_gate{' "$O/textfile/auto-mitamae.prom")"
rm -f "$O/canary2.invalid.sleep"

# review D5: empty file, string canary, duplicate host are refused
cp "$O/hosts.json" "$O/hosts.json.bak"
: > "$O/hosts.json"; run_orch "status=success sha=$EXP drift=1 duration=4 old=$SHA_A verified_sha=$EXP ts=now" 0
assert_eq "s3/D5 empty hosts.json → refused" 1 "$ORC"
printf '[{"host":"canary.invalid","user":"root","role":"pve/lxc-canary.rb","label":"canary","canary":true},{"host":"fleet.invalid","user":"root","role":"pve/lxc-fleet.rb","label":"fleet","canary":"true"}]\n' > "$O/hosts.json"
run_orch "status=success sha=$EXP drift=1 duration=4 old=$SHA_A verified_sha=$EXP ts=now" 0
assert_eq "s3/D5 string canary → refused" 1 "$ORC"
printf '[{"host":"canary.invalid","user":"root","role":"pve/lxc-canary.rb","label":"canary","canary":true},{"host":"canary.invalid","user":"root","role":"pve/lxc-other.rb","label":"canary-b"}]\n' > "$O/hosts.json"
run_orch "status=success sha=$EXP drift=1 duration=4 old=$SHA_A verified_sha=$EXP ts=now" 0
assert_eq "s3/D5 duplicate host → refused" 1 "$ORC"
mv "$O/hosts.json.bak" "$O/hosts.json"

# ---------------------------------------------------------------- summary
echo
echo "auto-mitamae state scenarios: $pass passed, $fail failed (mitamae calls total: $(calls))"
[[ "$fail" -eq 0 ]]
