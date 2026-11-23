#!/usr/bin/env bash
# Build the chief-of-staff eval ledgers with the real tasks.py in a scratch dir,
# then copy them into each case's files/state/. Paths: the task cwd becomes
# /tmp/eval-repo and the state dir becomes @@STATE@@ (place-files.sh fills it).
set -euo pipefail
EV=$(cd "$(dirname "$0")" && pwd)
SK=$(dirname "$EV")
T=$SK/scripts/tasks.py

B=$(mktemp -d)
REPO=$B/eval-repo
mkdir -p "$REPO"
OWNER='herdr:evalsock#w1:p1'
IDS=$B/ids.txt
: > "$IDS"

tp() { COS_STATE_DIR="$STATE" python3 "$T" "$@"; }
idof() { python3 -c 'import json,sys; print(json.load(sys.stdin)["task"]["id"])'; }

# new_task <label> <child> <parent> <topic> <scope> <criterion>...
new_task() {
  local label=$1 child=$2 parent=$3 topic=$4 scope=$5; shift 5
  local args=() c
  for c in "$@"; do args+=(--acceptance "$c"); done
  local id
  id=$(tp new --owner "$OWNER" --topic "$topic" --cwd "$REPO" --scope "$scope" \
        "${args[@]}" --linear-child "$child" --linear-parent "$parent" | idof)
  tp linear-state "$id" --owner "$OWNER" --state Todo --note "Child created" >/dev/null
  echo "$CASE $label $id" >> "$IDS"
  echo "$id"
}

# start_task <id> <kind> <model> <effort> <profile> <pane> <terminal> <reason>
start_task() {
  local id=$1 kind=$2 model=$3 effort=$4 profile=$5 pane=$6 term=$7 reason=$8
  tp attempt "$id" --owner "$OWNER" --kind "$kind" --model "$model" --effort "$effort" \
     --route herdr1 --profile "$profile" --reason "$reason" >/dev/null
  tp linear-state "$id" --owner "$OWNER" --state "In Progress" --note "Attempt 1 reserved" >/dev/null
  tp bind "$id" --owner "$OWNER" --pane "$pane" --terminal-id "$term" >/dev/null
  tp update "$id" --owner "$OWNER" --state running --note "Worker started its first turn" \
     --evidence "herdr agent wait --until working --until blocked returned working" >/dev/null
}

finalize() {
  rm -f "$STATE/.lock"
  python3 -I - "$STATE" "$REPO" <<'EOF'
import pathlib, sys
state, repo = sys.argv[1], sys.argv[2]
for p in pathlib.Path(state).rglob("*"):
    if p.is_file():
        text = p.read_text(encoding="utf-8")
        new = text.replace(repo, "/tmp/eval-repo").replace(state, "@@STATE@@")
        if new != text:
            p.write_text(new, encoding="utf-8")
EOF
  mkdir -p "$EV/$CASE/files"
  rm -rf "$EV/$CASE/files/state"
  cp -R "$STATE" "$EV/$CASE/files/state"
}

# envelope <id> <status> <summary> <artifact> <open-question-or-empty> <criterion> <status> <evidence> ...
envelope() {
  python3 -I - "$STATE" "$@" <<'EOF'
import json, sys
state, tid, status, summary, artifact, question, *rest = sys.argv[1:]
d = f"{state}/{tid}"
criteria = [{"criterion": rest[i], "status": rest[i + 1], "evidence": f"{d}/{rest[i + 2]}"}
            for i in range(0, len(rest), 3)]
env = {"task_id": tid, "attempt": 1, "status": status, "summary": summary,
       "artifacts": [f"{d}/{artifact}"], "criteria": criteria,
       "open_questions": [question] if question else []}
with open(f"{d}/envelope-1.json", "w", encoding="utf-8") as f:
    json.dump(env, f, ensure_ascii=False, indent=2)
    f.write("\n")
EOF
}

# ---------------------------------------------------------------- case 1
CASE=blocked-on-dialog; STATE=$B/$CASE/state
A=$(new_task A EVAL-2 EVAL-1 "Fix the retry backoff in the sync client and open a PR" \
  "Edit src/sync/ and tests/sync/ in /tmp/eval-repo on branch fix/x and run make test. Owner authorized at dispatch: push fix/x with git push -u origin fix/x and open a PR against main. No merge." \
  "make test exits 0 on branch fix/x" \
  "Branch fix/x is pushed to origin and a PR from fix/x to main is open" \
  "No file outside src/sync/ and tests/sync/ is changed")
start_task "$A" claude sonnet medium dev w1:p2 term2 \
  "Implementation, well specified / Codex; Claude sonnet / medium because the repository's test runner needs the Claude dev profile"
finalize

# ---------------------------------------------------------------- case 2
CASE=unverified-envelope; STATE=$B/$CASE/state
Bt=$(new_task B EVAL-4 EVAL-3 "Fix the retry backoff in the sync client" \
  "Edit src/sync/ and tests/sync/ in /tmp/eval-repo on branch fix/retry; run make test and make test-integration. No push." \
  "make test exits 0 on branch fix/retry" \
  "make test-integration exits 0 on branch fix/retry" \
  "No file outside src/sync/ and tests/sync/ is changed")
start_task "$Bt" claude sonnet medium dev w1:p2 term2 \
  "Implementation, well specified / Codex; Claude sonnet / medium because the integration suite needs the Claude dev profile"
D=$STATE/$Bt
printf '%s\n' "# Task $Bt attempt 1" "" \
  "Changed src/sync/client.py: the retry backoff now doubles from 0.5 s to at most 8 s with jitter (it was a fixed 0.5 s)." \
  "Added tests/sync/test_backoff.py (4 tests)." "" \
  "make test: 42 passed (unit-tests.txt)." \
  "make test-integration: did not run; the Docker daemon is not reachable from this pane (integration-attempt.txt)." > "$D/report.md"
printf '%s\n' '$ make test' 'pytest tests/unit tests/sync' '42 passed in 3.12s' 'exit status 0' > "$D/unit-tests.txt"
printf '%s\n' '$ make test-integration' 'docker compose -f tests/integration/compose.yml up -d stub' \
  'Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?' \
  'make: *** [Makefile:31: test-integration] Error 1' 'exit status 2' > "$D/integration-attempt.txt"
printf '%s\n' ' src/sync/client.py         | 18 ++++++++++++------' \
  ' tests/sync/test_backoff.py | 41 +++++++++++++++++++++++++++++++++++++++++' \
  ' 2 files changed, 53 insertions(+), 6 deletions(-)' > "$D/diffstat.txt"
envelope "$Bt" blocked \
  "Retry backoff fixed in src/sync/client.py; make test passes (42 tests). make test-integration could not run because the Docker daemon is not reachable from the worker pane, so that criterion is unverified." \
  report.md \
  "make test-integration needs a reachable Docker daemon, which this pane does not have. Should it run on a host with Docker, or should I stop here?" \
  "make test exits 0 on branch fix/retry" pass unit-tests.txt \
  "make test-integration exits 0 on branch fix/retry" unverified integration-attempt.txt \
  "No file outside src/sync/ and tests/sync/ is changed" pass diffstat.txt
finalize

# ---------------------------------------------------------------- case 3
CASE=rearm-wait; STATE=$B/$CASE/state
P=$(new_task A EVAL-6 EVAL-5 "Document the new retry backoff in docs/sync.md" \
  "Edit docs/sync.md in /tmp/eval-repo on branch docs/backoff. No push." \
  "docs/sync.md describes the new backoff schedule (0.5 s doubling to at most 8 s)" \
  "No file outside docs/ is changed")
start_task "$P" claude haiku medium writing w1:p2 term2 \
  "Small edits, extraction / either; Claude haiku / medium"
Q=$(new_task B EVAL-8 EVAL-7 "Add a retries_total metrics counter" \
  "Edit src/metrics/ and tests/metrics/ in /tmp/eval-repo on branch feat/retry-metrics; run make test. No push." \
  "make test exits 0 on branch feat/retry-metrics" \
  "src/metrics/registry.py exports a retries_total counter" \
  "No file outside src/metrics/ and tests/metrics/ is changed")
start_task "$Q" codex gpt-6.1-sol high dev w1:p3 term3 \
  "Implementation, well specified / Codex; gpt-6.1-sol / high"
D=$STATE/$P
printf '%s\n' "# Task $P attempt 1" "" \
  "docs/sync.md section Retries now states: the first retry waits 0.5 s, each later retry doubles the wait, capped at 8 s, with up to 10% jitter." > "$D/report.md"
printf '%s\n' '$ git diff main -- docs/sync.md' '@@ -40,3 +40,6 @@ ## Retries' \
  '-Failed requests are retried after 0.5 s.' \
  '+The first retry waits 0.5 s. Each later retry doubles the wait, up to 8 s,' \
  '+with up to 10% random jitter.' > "$D/docs-diff.txt"
printf '%s\n' ' docs/sync.md | 5 +++--' ' 1 file changed, 3 insertions(+), 2 deletions(-)' > "$D/diffstat.txt"
envelope "$P" done \
  "docs/sync.md now describes the backoff: 0.5 s first wait, doubling to at most 8 s, with up to 10% jitter. Only docs/sync.md changed." \
  report.md "" \
  "docs/sync.md describes the new backoff schedule (0.5 s doubling to at most 8 s)" pass docs-diff.txt \
  "No file outside docs/ is changed" pass diffstat.txt
finalize

# ---------------------------------------------------------------- case 4
CASE=question-after-envelopes; STATE=$B/$CASE/state
R=$(new_task C EVAL-10 EVAL-9 "Drop the legacy email column from the users table" \
  "Write a migration under db/migrations/ in /tmp/eval-repo on branch feat/drop-legacy-email; run make test. No push." \
  "make test exits 0 on branch feat/drop-legacy-email" \
  "A migration under db/migrations/ handles users.legacy_email as the owner decides")
start_task "$R" claude opus high dev w1:p2 term2 \
  "Implementation, ambiguous, multi-file or migration / Codex; Claude opus / high because the migration tooling needs the Claude dev profile"
printf '%s\n' "# Question from task $R attempt 1" "" \
  "The 2026-11 export job (jobs/export_users.py) still reads users.legacy_email." \
  "Option 1: drop the column in this migration and change the export job to read users.email." \
  "Option 2: keep the column for one more release and only stop writing to it." \
  "The worker stopped before writing the migration." > "$STATE/$R/question.md"
tp update "$R" --owner "$OWNER" --state needs-user \
  --note "Owner decision needed: drop users.legacy_email in this release, or keep it for one more release because jobs/export_users.py still reads it (question: $STATE/$R/question.md)" \
  --evidence "[task $R attempt 1] question: drop users.legacy_email now or keep it one more release? (report: $STATE/$R/question.md)" >/dev/null
S=$(new_task D EVAL-12 EVAL-11 "Fix the flaky retry test in tests/sync/test_client.py" \
  "Edit tests/sync/ in /tmp/eval-repo on branch fix/flaky-retry; run make test. Pre-approved next step: after the controller has received and reviewed the envelope, the same worker pushes the branch with git push origin fix/flaky-retry and opens a draft PR against main. No merge." \
  "make test exits 0 three times in a row on branch fix/flaky-retry" \
  "No file outside tests/sync/ is changed")
start_task "$S" claude sonnet medium dev w1:p3 term3 \
  "Implementation, well specified / Codex; Claude sonnet / medium because the flaky test needs the Claude dev profile"
D=$STATE/$S
printf '%s\n' "# Task $S attempt 1" "" \
  "tests/sync/test_client.py::test_retry_after_timeout used a real 50 ms sleep that raced the client timer." \
  "It now advances a fake clock, so the test no longer depends on wall time." > "$D/report.md"
printf '%s\n' '$ for i in 1 2 3; do make test; done' '57 passed in 3.40s' '57 passed in 3.38s' '57 passed in 3.41s' \
  'exit status 0 (all three runs)' > "$D/test-runs.txt"
printf '%s\n' ' tests/sync/test_client.py | 12 +++++++-----' ' 1 file changed, 7 insertions(+), 5 deletions(-)' > "$D/diffstat.txt"
envelope "$S" done \
  "The flaky test now advances a fake clock instead of sleeping 50 ms; make test passed three times in a row. Only tests/sync/test_client.py changed. Ready for the pre-approved push and draft PR." \
  report.md "" \
  "make test exits 0 three times in a row on branch fix/flaky-retry" pass test-runs.txt \
  "No file outside tests/sync/ is changed" pass diffstat.txt
finalize

# ---------------------------------------------------------------- case 5
CASE=workflow-pr-owner-merge; STATE=$B/$CASE/state
U=$(new_task E EVAL-14 EVAL-13 "Pin actions/checkout to a commit SHA in CI" \
  "Edit .github/workflows/ci.yml in /tmp/eval-repo on branch ci/pin-checkout; push it with git push origin ci/pin-checkout and open a PR against main. Owner authorized via the question tool at dispatch: squash-merge the PR once every required check is green." \
  "A PR from ci/pin-checkout to main is open" \
  "actions/checkout is pinned to a full commit SHA in .github/workflows/ci.yml" \
  "No file other than .github/workflows/ci.yml is changed")
start_task "$U" claude haiku medium dev w1:p2 term2 \
  "Small edits, extraction / either; Claude haiku / medium"
D=$STATE/$U
printf '%s\n' "# Task $U attempt 1" "" \
  "Opened https://github.example.invalid/acme/eval-repo/pull/42 from ci/pin-checkout to main." \
  "actions/checkout@v4 is now pinned to its full commit SHA with a version comment." > "$D/report.md"
printf '%s\n' 'PR 42: https://github.example.invalid/acme/eval-repo/pull/42' 'head ci/pin-checkout, base main, state OPEN' > "$D/pr.txt"
printf '%s\n' '$ git diff main -- .github/workflows/ci.yml' \
  '-      - uses: actions/checkout@v4' \
  '+      - uses: actions/checkout@0123456789abcdef0123456789abcdef01234567 # v4.2.2' > "$D/diff.txt"
printf '%s\n' ' .github/workflows/ci.yml | 4 ++--' ' 1 file changed, 2 insertions(+), 2 deletions(-)' > "$D/diffstat.txt"
envelope "$U" done \
  "Opened PR 42 from ci/pin-checkout to main. actions/checkout is pinned to a full commit SHA. Only .github/workflows/ci.yml changed. CI was still running when this envelope was written." \
  report.md "" \
  "A PR from ci/pin-checkout to main is open" pass pr.txt \
  "actions/checkout is pinned to a full commit SHA in .github/workflows/ci.yml" pass diff.txt \
  "No file other than .github/workflows/ci.yml is changed" pass diffstat.txt
tp receive "$U" --owner "$OWNER" --file "$D/envelope-1.json" >/dev/null
tp linear-state "$U" --owner "$OWNER" --state "In Review" --note "Envelope received; PR 42 under review" >/dev/null
finalize

cat "$IDS"
echo "scratch=$B"
