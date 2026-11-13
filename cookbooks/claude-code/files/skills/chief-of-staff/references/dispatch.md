# Routing and Herdr dispatch

## Routing is a decision, not a benchmark claim

Choose using this task's needed tools, available skills, and observed outcomes.
These are starting preferences; tool availability and user choice take priority.

| Topic | Initial choice | Reason to switch |
|---|---|---|
| Code changes, debugging, tests, reproducible operations | Codex with its configured model | Required integration exists only in Claude, or repeated implementation failure |
| Research, synthesis, writing, planning, open-ended discussion | Claude with its configured model | Needed source/tool exists only in Codex, or unsupported conclusions persist |
| Cross-domain request | Split into deliverables with explicit dependencies | One harness has all required tools and splitting would lose necessary context |
| Review of consequential work | Separate context, often the other harness | Direct observable verification is available and a model review adds no evidence |

Check installed `codex --help`, `claude --help`, and model availability before
adding launch flags. `codex debug models` is usable only when listed by that
installation's `codex debug --help`; inspect the model's supported effort fields.
Claude's current `--help` describes supported model aliases; account availability
is confirmed by actual startup, not by an alias appearing in help. Do not pin
obsolete model versions in this skill or claim one provider is universally best.
Inspect startup/response errors as well: an installed CLI can still be out of
quota or unauthenticated. Record the observed unavailable harness and any stated
reset time, route feasible work to the other harness, and do not try several
models against the same account-wide limit. Recheck once the stated reset has
passed or the user reports restored access. Do not purchase credits or alter
authentication to complete a retry without the necessary authorization.

Leave permission/sandbox settings at the user's configured policy. Never add
`--dangerously-skip-permissions`, `--dangerously-bypass-approvals-and-sandbox`,
or a trust bypass to make orchestration unattended. CLI options such as old
Codex `--full-auto` / `-a` are version-dependent and may no longer exist.

## Ledger operations

Run the helper from the loaded skill directory; do not assume a checkout path.
All commands produce JSON. `COS_STATE_DIR` overrides the default
`~/.local/state/chief-of-staff`. This private local state is not committed or
uploaded. Store enough context to resume, but never copy secrets into briefs.

```text
# First resolve the project and duplicate-check/create parent and child (linear.md).
python3 <skill-dir>/scripts/tasks.py new --owner <socket#controller-pane> \
  --topic <topic> --cwd <absolute-dir> --scope <authorized-scope> \
  --acceptance <criterion> [--acceptance <criterion> ...] \
  --linear-child <child-identifier> --linear-parent <parent-identifier>
# Prepare the launch plan; see "Worker profiles and launch plans".
python3 <setup-checkout>/bin/worker-profile prepare --harness codex --route <hc|herdr1> --profile <profile> ...
# When using the validated plan, record its path on the reserved attempt.
python3 <skill-dir>/scripts/tasks.py attempt <task-id> --owner <verified-owner> \
  --kind codex --model <verified-model> --effort <verified-effort> --profile <profile> \
  --route <hc|herdr1> --plan <absolute-launch-plan.json> --reason <routing-or-repair-reason>
python3 <skill-dir>/scripts/tasks.py bind <task-id> --owner <verified-owner> --pane <returned-pane-id>
# Launch through the verified route.
python3 <skill-dir>/scripts/tasks.py update <task-id> --owner <verified-owner> --state running \
  --note <observed-start> --evidence <observed-working-transition>
# After the worker's first turn, record its effective model/effort from its own log.
python3 <skill-dir>/scripts/tasks.py observe <task-id> --owner <verified-owner> \
  --transcript <absolute-session-log> --launch-prompt <exact-launch-prompt>
python3 <skill-dir>/scripts/tasks.py receive <task-id> --owner <verified-owner> \
  --file <absolute-envelope-file>
# Run the independent check first and save its output under the task directory or checkout.
python3 <skill-dir>/scripts/tasks.py check <task-id> --owner <verified-owner> \
  --file <absolute-check-output> --exit-status <check-exit-status> --note <what-was-checked>
# Read the check output and the printed check ID, then accept in a later, separate call.
python3 <skill-dir>/scripts/tasks.py update <task-id> --owner <verified-owner> --state accepted \
  --check <id-printed-by-check> --note <criterion-by-criterion-verdict> --evidence <independent-check>
python3 <skill-dir>/scripts/tasks.py reported <task-id> --owner <verified-owner> --note <message-sent>
python3 <skill-dir>/scripts/tasks.py list --owner <socket#controller-pane>
python3 <skill-dir>/scripts/tasks.py show <task-id>
```

Use the same route vocabulary in `prepare` and `attempt`: `hc` for Herdr 2,
`herdr1` for Herdr 1, and `agent` for the Agent tool. Pass the route explicitly
for every new dispatch; omission retains legacy `herdr` for old callers.
`--plan` records
the file used for a fresh profile launch on the attempt (`show` exposes `route`
and `plan`); omit it for a fresh default launch, which records `plan: null`.
The path must be absolute, point to an existing JSON file, and name the same
route as the attempt. This validation does not prove the plan was executed.
Attempts snapshot the plan JSON and `--launch-options '<JSON argv array>'`
(additional native CLI options). Reused workers inherit these and the profile;
a different plan, options, or profile is refused. The snapshot preserves the
original environment/options even if the plan file later changes.

Legacy `herdr` records, and records without a route, mean an unspecified
terminal route: either `hc` or `herdr1`. They keep pane/terminal binding and
session-log observation; never infer which route they used or rewrite their
history. `--route herdr` remains accepted for old callers, but new callers use
the three explicit routes. Reusing a worker requires the same recorded route;
an unspecified legacy route is not automatically equivalent to either one.

`attempt` reserves the next attempt and a unique Herdr name before any terminal mutation.
When the user explicitly requests a new agent or separate pane, create the task
with `new --fresh-worker`. Its attempt and bind operations reject reuse. Use a
new pane returned by a fresh split, even if an old worker is idle.
Unless the user requests a new agent or separate pane, for a correction to the same settled worker, pass `--reuse-agent` with the same
kind/model/effort/route: this consumes an attempt but retains its live name and
launch plan. Pass the recorded `--route`, omit `--plan`, and skip `prepare`.
Normally the old pane has already been closed: resume its observed session in a
new pane using the recipe below. If it is still live, confirm it is the same
settled worker before prompting it; never run the same session concurrently.
Changing harness/model/effort uses a fresh worker.
Keep the JSON output: it includes `agent` and `attempt`. Save the full worker
brief to a private task-local file under the returned task directory using a
file-write tool. It is the controller handoff record. For envelope-v1 tasks the worker must
write the full answer and test evidence as task-local or checkout artifacts,
then return only the bounded envelope. `bind` records the returned pane before
`agent start`; if an interrupted split has no recorded ID, inspect topology
and refuse to guess or blindly create another pane.

Follow [linear.md](linear.md) at each state change: Todo at creation, In Progress
at reservation/start/retry, In Review on envelope/PR review, a question comment
without changing state at needs-user, and a closing comment plus confirmed and
recorded Done/Canceled before accepted/cancelled. Run `linear-audit` at each
report/handoff; close the parent after all children and the owner report.

Acceptance is three steps, never one shell command. (1) Run the independent
check and save its output to a file. (2) Record it with `check`, which stores
the file path, its sha256, the exit status and a timestamp on the current
attempt and prints a check ID. (3) Read the check output, then run
`update --state accepted --check <id>` in a later call. For envelope-v1 tasks
`accepted` is refused when the current attempt has no recorded check, when the
latest recorded check has a non-zero exit status, or when `--check` does not
name that latest check. A new attempt starts with no checks. Never chain the
check, `check` and `accepted` in one command line: the ID exists so that the
acceptance follows reading the result.

Use `update --state retry --note ... --evidence ...` after a failed review;
it automatically becomes `needs-user` at the attempt limit. `attempt` also
refuses to exceed the limit. `needs-user` can be resumed with another `attempt`
once its blocker is resolved, within the existing budget. Explicit user budget
extensions use `extend <task-id> --max-attempts <N> --note <user-instruction>`.
Use `update --state cancelled` for cancellation. Use `update --state needs-user`
for an actual external/authorization blocker or stopped supervision.
To resume monitoring the same worker, use `update --state running` (or
`starting`/`reviewing` matching the observed state) with new live evidence;
do not create another attempt just because the controller was interrupted.
If reservation failed after preparation, first `show` the task and reconcile
its state. Re-read and validate the saved plan, then retry `attempt` with that
same plan file. Do not run `prepare` again into the existing directory or
silently switch to a default launch because reservation failed. For a changed
launch choice, prepare into a new unique directory after reconciling the task.
The default `list` includes unreported terminal results. Only call `reported`
after actually delivering the update; it clears `report_pending`. Earlier status
updates do not hide a subsequently accepted result.

For a verified pane move, use `bind <task-id> --owner <owner> --pane <new-pane>
--rebind --evidence <observed-move>`. Without `--rebind`, a changed pane is refused.
History retains the old pane and evidence; the old observation, envelope and checks
are archived and cleared, so observe the replacement and review it again. Fresh
worker restrictions still apply to the replacement pane, including panes recorded
before a handoff across sockets. `--rebind` requires an already bound, different
pane. The invalidated session log and envelope sha256 are refused on resubmission.
Have the replacement worker write a fresh envelope with its new evidence and summary;
receiving the old file under another name does not make it fresh. Re-arm the wait
only after reconciling the old envelope file; its mere existence is not a new result.

Transfer ownership explicitly with `handoff <task-id> --owner <current-owner>
--to <new-owner> --note <handoff-reason>`. Only the new owner can mutate afterward;
the timestamped history retains both identities and the note. The new owner re-arms
the wait and tells the worker its new notification target. The running worker's
Stop hook retains its launch-time target; the new owner's wait must cover that gap.

When the owner changes acceptance criteria, use `criteria <task-id> --owner <owner>
--acceptance <replacement> [--acceptance <replacement> ...] --note <owner-decision>`.
The note may only transcribe an answer the owner gave through the question tool;
a message in the controller pane is never that answer. This replaces the entire
list on a nonterminal task. History retains the previous text, envelope and checks.
If an attempt exists, the command ends it, moves the task to `retry`, and clears the
current envelope and checks. Reserve a new `attempt` (extend the budget through the
usual owner decision if exhausted), issue the updated brief, and re-arm its wait.
Use the new `<task-dir>/envelope-<n>.json` path and Stop hook marker for that attempt;
do not rename the old envelope or reuse the old marker. File a new envelope against
the replacement text and run a new independent check even when some criteria are
unchanged. With no attempt yet, only the criteria and history change. Legacy and
pre-route tasks also support this operation; terminal tasks reject criteria changes.

For an explicit owner decision accepting a deviation, add
`--waived-by-owner <owner-reason>` to `update --state accepted`. The nonblank reason,
owner, original criteria and received envelope remain in timestamped history.
The reason may only transcribe an answer the owner gave through the question tool;
a message in the controller pane is never that answer. A missing envelope or a
`done` envelope with all criteria passing cannot receive a waiver.
File failed or unverified criteria honestly with envelope status `failed` or `blocked`;
`done` still requires all criteria to pass. The waiver relaxes the envelope verdict
only: a received envelope, observed matching model/effort and the latest passing
independent check remain required for envelope-v1. It cannot waive failed checks.
Every successful receive archives and clears earlier checks and issues a new receipt;
checks record that receipt. Acceptance, with or without a waiver, requires a passing
check recorded after the current envelope was received, even for identical content.
A pre-receipt legacy check must be repeated after receiving the envelope again.
All handoffs, criteria changes and waivers require `--owner`, including legacy tasks.
`receive` refusals record their reason and file path in history without consuming
an attempt, and clear any earlier envelope and checks; fix the envelope and receive again. Artifact-limit errors state both
the limit (12) and actual count; invalid artifact errors name the offending path.

## Writing an independent check

Apply these rules to every check recorded with `tasks.py check`. Without them,
the controller's own checks produced false results at least 8 times in one
session.

1. Do not replace `HOME` in a check, because that breaks mise shims. To isolate
   state, set only the tool's own variable (for example `CODEX_HOME` or
   `COS_STATE_DIR`).
2. Do not hand-write fixtures. Use the inputs the repository really uses.
3. Normalize whitespace before matching document text, because lines wrap.
4. Build "changed files are in scope" from the brief's File ownership line,
   including any recorded widening, not from a fixed list.
5. Enumerate tests with `git diff --name-only <base>...HEAD`, so tests a worker
   added are included, and run every test module that touches the mutated code.
6. When a check fails, first suspect the check. Record the classification
   (defect in the check or in the work) in the `tasks.py check` note, and keep
   the failed run's output in its own file before re-running. Correcting a check
   never lowers the bar its criterion sets.

## Merging

Merge only with the authorization `SKILL.md` requires; this section grants none.
Every squash merge passes an explicit English subject:

```text
gh pr merge <PR> --squash --subject "<English subject> (#<PR>)"
```

Without `--subject`, `gh` uses the PR title, so a Japanese title produced a
Japanese commit subject (commit 6110818).

## Launch example

These are shapes, not commands to paste with placeholder IDs. Use actual JSON
IDs and pass shell arguments with a file-based subprocess argv list or correct
shell quoting; user topics are data, never shell commands.

```text
herdr --session <verified-session> pane layout --pane <verified-caller-pane>
herdr --session <verified-session> pane split --pane <verified-caller-pane> --direction right --cwd <task-cwd> --no-focus \
  [--env COS_WORKER_TASK_ID=<task-id> --env COS_WORKER_ATTEMPT=<attempt> \
   --env COS_CONTROLLER_PANE=<verified-caller-pane> --env COS_CONTROLLER_SESSION=<verified-session>]
# Start either Claude or Codex with the common start step below.
# It waits for working or blocked and restores a lost agent name.
herdr --session <verified-session> agent get <reserved-agent-name>
herdr --session <verified-session> agent read <reserved-agent-name> --source recent-unwrapped --lines 40
# Then run the wait loop below in the background so the harness wakes the controller when it ends.
# A later prompt to the same worker, once it is settled.
herdr --session <verified-session> agent prompt <reserved-agent-name> <text> --wait --until working --until blocked --timeout 30000
```

This is today's launch, used whenever the attempt's launch plan is not ready
(see "Worker profiles and launch plans"); a ready plan adds `--env` to the
split and replaces the options after `--`.

Give a new worker its first prompt as an argument after `--`: a one-line
`<launch-prompt>` naming the brief file, before any variadic flag such as
`--tools`. Do not type it with `agent prompt` right after `agent start`. In 4 of
5 launches on 2026-11-09 the Enter was lost during startup: `agent prompt` exited
1 with `agent_prompt_stalled` and the text stayed in the input box with the state
`idle`. If that happens, confirm the text is in the box with `agent read`, send
`agent send-keys <name> Enter` once, and do not send the prompt again.

Both forms use `--until working --until blocked`. Without `--until`, `--wait`
lasts until the turn ends and exits 1 on any normal turn longer than the timeout.

The background wait runs in this loop, one per worker, with `s`, `worker` and
`envelope` (`<task-dir>/envelope-<n>.json`) set first. It reads the envelope file
directly, so a worker that writes it while settled cannot be missed, and a turn
that ends while the worker's own background job runs costs no wake.

```bash
end=$((SECONDS+600)); why=timeout
while [ $SECONDS -lt $end ]; do
  [ -f "$envelope" ] && { why=envelope; break; }
  herdr --session "$s" agent get "$worker" >/dev/null 2>&1 || { why=gone; break; }
  herdr --session "$s" agent wait "$worker" --until blocked --timeout 15000 >/dev/null 2>&1 && { why=blocked; break; }
done
echo "reason=$why"
```

The last line decides the controller's next step:

| Output | Meaning | Next step |
| --- | --- | --- |
| `reason=envelope` | The attempt's envelope exists | Run `receive`, then review |
| `reason=blocked` | The worker is at a dialog | Read the dialog and report it; never answer it. Wait in the background with `--until working --until idle --until done`, then re-arm the loop |
| `reason=gone` | `agent get` failed and no envelope exists | Treat as an abnormal exit: inspect the pane and logs, then repair or report. A failed socket call looks the same, so confirm with a second `agent get` |
| `reason=timeout` | Ten minutes passed | Look now, not a failure. Re-check state and re-arm. Without observable progress, run the stall diagnosis in `SKILL.md` |

Both harnesses use this start step: `agent start` with a first prompt can
return `timeout` or `agent_name_not_found` while the worker keeps working
(observed for Codex and Claude on 2026-11-09). Set `s`, `worker`, `pane`,
`kind` (`claude` or `codex`), `model`, `effort` and `launch_prompt` first.
The step accepts
those errors only when the wait that follows observes `working` or `blocked`. If
the name is lost, it restores it through the pane and checks again:

```bash
case "$kind" in
  claude) agent_args=("$launch_prompt" --model "$model" --effort "$effort") ;;
  codex) agent_args=(-m "$model" -c "model_reasoning_effort=$effort"
                    -c check_for_update_on_startup=false "$launch_prompt") ;;
  *) echo "unknown harness: $kind" >&2; exit 1 ;;
esac
# Add the task's Claude settings/tools from "Model and effort per attempt".
# With a ready plan, use its argv after the executable instead of agent_args.
herdr --session "$s" agent start "$worker" --kind "$kind" --pane "$pane" -- \
  "${agent_args[@]}" || true
delivered=1
for _ in $(seq 1 30); do
  if ! herdr --session "$s" agent get "$worker" >/dev/null 2>&1; then
    herdr --session "$s" agent rename "$pane" "$worker" >/dev/null 2>&1 || { sleep 1; continue; }
  fi
  out=$(herdr --session "$s" agent wait "$worker" --until working --until blocked --timeout 30000 2>&1) \
    && { echo "$out"; delivered=0; break; }
  case "$out" in *agent_not_found*) sleep 1 ;; *) echo "$out" >&2; break ;; esac
done
[ "$delivered" = 0 ]
```

A non-zero exit is ambiguous delivery. Inspect the pane with `pane read` and do
not launch again: the first worker may still be running.

Pass the four `COS_*` variables when the worker is Claude and the controller is
a Herdr 1 pane; add `--env COS_STATE_DIR=<dir>` when the controller set it. They
arm the Stop hook (`~/.claude/hooks/cos-worker-stop-notify.rb`), which sends
`[task <id> attempt <n>] envelope-ready` to the controller once, at the first
Stop after `<task-dir>/envelope-<n>.json` exists. Codex has no such hook, and a
controller on the `hc` route leaves the variables unset.

For explicit model selection, append native options **after** `--` (see
"Model and effort per attempt" for each harness), and record the resulting
effective model/effort with `observe` once the worker has answered at least
one turn. `bind` records only identity.
Wait for an actual shell/agent prompt rather than a fixed startup sleep. Do not
prompt a working agent or send slash commands as if they were normal task text.
For envelope-v1 tasks do not escalate to full pane history. Request the missing
envelope or delegate an artifact read. The installed Herdr skill's legacy
file-output fallback remains the rule for old tasks; the new explicit artifact
contract is an opt-in protocol, not a reason to alter an active legacy session.

## Close and resume workers

After `receive` and `observe`, on entry to `needs-user`, and at `accepted` or
`cancelled`, close settled worker/helper panes. A working agent always stays
open until it settles. Bind new Herdr 1 workers with `--terminal-id` from the
creation response, as well as `--pane`. Create helpers through the ledger so
their identity comes from a creation response, not a worker's arbitrary pane
claim. `helper-open` splits the recorded worker pane, stores the returned
shell pane and terminal ID, and returns them. After starting an authorized agent
in that new helper, update its kind/name with `helper`:

```bash
python3 "$skill/scripts/tasks.py" helper-open "$task" --owner "$owner" --herdr-session "$s"
python3 "$skill/scripts/tasks.py" helper "$task" --owner "$owner" \
  --pane "$helper_pane" --terminal-id "$helper_terminal" --kind "$helper_kind" --agent-name "$helper_name"
python3 "$skill/scripts/tasks.py" closable --owner "$owner" --herdr-session "$s"
```

`closable` is read-only by default, including its lock access. It inventories
every workspace, checks the session's socket against the owner key, and selects
only recorded idle/done agents with matching identities. For old records with
no terminal ID, both pane-list and agent-get must agree on terminal, kind and
idle/done, and agent-get must match the recorded agent name. The result's
`adoptions` list previews those identities without writing; explicit
`closable --adopt` persists them once with an adoption history entry.
Reviewing requires envelope receipt and observed matching model/effort.
Cancelled/accepted do not require fresh observation. needs-user requires an
explicit settled record and a native session UUID, not model observation:

```bash
python3 "$skill/scripts/tasks.py" settle "$task" --owner "$owner" \
  --session-id "$session_id" --note 'No unfinished work or background waits remain' \
  --evidence "$completion_evidence"
```

Confirm the native UUID from the harness's log/session metadata; never guess it.
`settle` records it separately from a refused model observation, so a worker
that stopped before observe can still be resumed safely. A supervision pause
uses `update --state needs-user --supervision-paused` and stays ineligible until
settle. Idle alone does not prove that background work has finished. While the
worker remains live, resume supervision with `update --state running`, without
spending another attempt; after closure use a new resume attempt.
It includes this owner's tasks and orphan tasks whose owning controller pane
is absent on that socket. Another live controller, running task, unknown agent,
ambiguous binding, unrecorded pane, unmatched identity, hc or remote route is
never selected. An explicit same-task/same-agent reuse chain on the same pane
is one binding, provided all known terminal IDs agree; different tasks or
unrelated attempts stay ambiguous. Helper claims without a `helper-open`
creation receipt never authorize closure. Legacy/route-less records remain
readable. A returned candidate is not a durable authorization: immediately
re-run the sweep and `pane get`, check the terminal ID and idle/done state, then
the controller runs `herdr --session "$s" pane close "$pane"`. On uncertain
state or changed ownership, skip. Do not close the controller itself.

For a later correction, reserve `attempt --reuse-agent` with the same
kind/model/effort/profile/route; omit `--plan` and `--launch-options` to inherit
their recorded snapshot. Create a new pane, bind it with its terminal ID, and
use the recorded profile plan to launch. Set `skill`, `task`, `owner`, `s`,
`pane`, and `prompt` (the new correction) first:

```bash
launch=$(python3 "$skill/scripts/tasks.py" launch-command "$task" \
  --owner "$owner" --prompt "$prompt") || exit 1
command=$(printf '%s' "$launch" | jq -r .command)
herdr --session "$s" pane run "$pane" "$command"
```

After the agent is ready, assign the attempt's recorded name with
`herdr --session "$s" agent rename "$pane" "$worker"`. The sweep checks this
occupant name as well as the terminal ID; either mismatch excludes the pane.
Use this same recipe for the initial launch from a ready plan. It runs
`claude --resume <session-id> <recorded-options> <prompt>` or
`codex resume <session-id> <recorded-options> <prompt>` on a resumed attempt,
preserving the plan's `env_unset`, `env_set`, argv, and additional launch
options. On hc it also sets PATH to the calling controller's actual PATH,
overriding the core's minimal default, for both initial launch and resume.
If an old attempt lacks profile, inherit the snapshot's profile if known;
otherwise record `profile: null` (unknown), never the newly requested label.
Launch in the task's recorded cwd; no `eval` is needed. For an old
attempt without a plan snapshot, inspect the original plan/options and use
those native commands manually; never manufacture a missing session ID.

After at least one new answer, run `observe --transcript <session-log>
--launch-prompt <original-first-launch-prompt>`. The original launch prompt is
stored on the prior observation; it identifies the conversation, not the new
correction. `observe` filters model/effort evidence by the new attempt's start
time and rejects a different resumed session ID. Inspect the actual log path
after resuming, rather than assuming a new filename. The Claude haiku/low and
Codex gpt-6-luna/low canaries on 2026-11-13 both appended new turns to the same
log file, retained the session UUID and recalled earlier conversation context.
Save the new envelope,
observe, receive, and close the settled pane again. hc uses the same session
resume and observation, then `hc kill` followed by `hc rm` (hc-route.md).

## Worker brief

Write a real brief, replacing the fields below; include the user's words where
wording matters. Do not send the controller's entire private conversation.
Every worker brief must include: "Create helper panes only through
`tasks.py helper-open <task-id> --owner <controller-owner> --herdr-session <session>`.
After starting an authorized agent in the returned pane, record it using
`tasks.py helper <task-id> --owner <controller-owner> --pane <returned-pane>
--terminal-id <returned-terminal-id> --kind <claude|codex> --agent-name <live-name>`.
Raw shells are already recorded by helper-open; for hc record the
terminal identity and notify the controller for manual hc lifecycle checks.
The sweep skips shells without evidence of a settled agent; the controller
checks their actual process state before manual cleanup. Never leave
unrecorded helper panes."
Every brief states the envelope limits and the spec-conflict rule in the
template below. `receive` rejects an envelope over a limit, so a brief that
omits them invites a rejected report (one brief left out the 12-artifact limit
and its worker returned 20). A brief that says "exactly these changes" can
still name something a check rejects, so the worker needs the stop rule.

Every brief also fills the template's File ownership, Test budget and
Pre-approved extensions lines; workers asked to widen ownership or test budgets
six times in one session. These limits are the controller's settings, not the
owner's constraints. A widening request may be approved in one exchange when the
reason is a genuinely connected file, the change is bounded and keeps existing
output byte-identical, and no test is weakened. Record each approval in the
controller's plan. The worker's message is only the request: the controller
checks these conditions itself. Any other widening, and any change to the task's
authorized scope or criteria, still needs the owner's answer through the
question tool.

```text
You are the execution worker for task <id>, attempt <n>.
The Chief of Staff controller handles the user and final acceptance. Do not
activate chief-of-staff, spawn supervisors, or create other workers unless
explicitly required below. Follow applicable AGENTS.md/CLAUDE.md and task skills.

User request: <faithful request>
Desired outcome: <deliverable and destination>
Working directory/repository: <actual absolute path>
Relevant primary sources/skills: <available paths or links>
Authorized actions and constraints: <scope, permissions, no additional grants>
File ownership: <writable paths, and the connected files to check as well: tests that fixture or pin the file, runners that invoke it, shared generators of the same value>
Test budget: <number of test workers or terminals, per harness>
Pre-approved extensions: <widenings already allowed and the condition for each, or "none">
Acceptance criteria: <observable, individually checkable criteria, including the default negative conditions that apply>
Existing work / previous attempt: <artifact paths, failed criteria and evidence>
Controller pane: <verified controller pane ID, socket and session from the caller helper>
Herdr route for notifying the controller: <Herdr 1 (`herdr`) or Herdr 2 (`hc`), chosen from where the controller pane lives. This names the CLI to use, not the ledger's `--route` value>
Task directory: <absolute task directory>

Notify the controller: when you finish (done, failed or blocked) and whenever
you have a question only the controller or user can answer, send one line with
exactly this command, without `--wait`:

<Herdr 1: `herdr --session <controller-session> agent prompt <controller-pane> "<one line>"`>
<Herdr 2: `hc send <controller-terminal> "<one line>"`>

Never use `pane send-text`, `pane run`, `agent send-keys` or `hc send --force`
for this: they can type into a dialog. If the send is refused because the
controller is blocked (`agent_blocked` on Herdr 1), retry up to 5 times at 30 s
intervals, then stop trying; the controller also watches you.
Format: `[task <id> attempt <n>] done|failed|blocked|question: <one sentence> (report: <absolute path>)`.
The one-line message only points to the report or question; the full content
stays in the artifact files. Keep working on anything independent of the
question; do not wait idle without sending it.

Stay within File ownership and Test budget, apart from what Pre-approved
extensions allows. To widen either, send a `question:` line naming the file or
budget and the reason, and do not widen it until the controller answers.

Close what you open: close every pane you created yourself for this task
(helper shells, test or log panes) as soon as you no longer need it, after
reading anything you still need from it. Create Herdr helpers only with
`tasks.py helper-open <task-id> --owner <controller-owner-key> --herdr-session <session>`;
it saves the creation receipt. After launching an authorized agent, record it with
`tasks.py helper <task-id> --owner <controller-owner-key> --pane <returned-pane>
--terminal-id <returned-terminal-id> --kind <claude|codex|shell>`; agent helpers
also require `--agent-name <live-name>`. Never register an existing unrelated
pane as a helper. For hc, save the creation response and terminal ID in a task
artifact and notify the controller for manual cleanup; do not use the Herdr 1
helper-open/helper commands for hc terminals. Never leave unrecorded helpers.
Close only settled panes you created, never
the controller pane and never your own worker pane (the controller closes that
after envelope/observe, on needs-user, or at accepted/cancelled; a later
correction resumes the same session in a new pane).

Complete the authorized work and perform the relevant checks. Distinguish facts
from assumptions; report concrete blockers rather than answering permission
dialogs on behalf of the user. Preserve other agents' changes. Do not weaken
the acceptance criteria. Do not send messages to third parties without explicit
authorization. Write full results and actual check output to artifact files inside the supplied
task directory or checkout. Write the envelope below to
`<task directory>/envelope-<n>.json` (at most 16 KiB) and return only that.
Envelope limits: at most 12 artifacts; at most 8 open questions, each at most
600 UTF-8 bytes; summary at most 1200 UTF-8 bytes. Cite a single log or index file
instead of listing more than 12 paths; all cited paths must be regular files.
If the specification cannot pass a required check (a lint, test or validator
rejects what the brief asks for), stop. Report status `blocked` with the failing
check, its output file, and the specification change it needs. Never deviate
from the specification silently, even to make the check pass.
Do not paste full logs or documents into the controller response. Leave the
terminal ready for review.
```

## Default negative conditions

Add these to a task's acceptance criteria by default, each one that applies as
its own `--acceptance` criterion written for this task. Reviewers found defects
after every worker's own criteria had passed, because the criteria stated only
positive behavior.

- Default output, permissions and routes do not change.
- The procedure holds on every harness and route it claims to cover, not only
  the one tested.
- User settings such as the permission policy are inherited.
- At least one failure or race case is tested for any state machine touched.
- A mutation requirement targets every gate in the diff.

When the task's purpose is to change one of these, such as a default output, the
criteria state the intended change instead.

## Reviewer brief

A reviewer receives the original brief, criteria and raw artifacts with no
desired verdict (`SKILL.md`, "Evaluate, repair, deliver"). Every reviewer brief
also includes these lines:

```text
Default negative conditions: <the list in "Default negative conditions", applied to this diff even where the worker's criteria omit them>
Operation limits: avoid scripts containing `rm` and other commands that look
destructive. Do any reproduction with read-only commands in a clone under your
task directory (<absolute task directory>). Do not edit the worker's checkout.
```

The operation limits exist because a reviewer stopped at a permission dialog for
about two minutes. They make a dialog less likely and change nothing about
handling one: the controller still never answers a permission dialog, and waits
for it to resolve (`reason=blocked` in "Launch example").

## Envelope-v1 and owner binding

New `tasks.py new` records default to envelope-v1; old JSON records without a
contract retain the legacy protocol. Never convert an active task implicitly.
All envelope-v1 mutations pass `--owner` from the verified caller helper.
The string check prevents accidental cross-controller edits; it is not an
authentication boundary or a substitute for Herdr caller verification.

```json
{"task_id":"<id>","attempt":1,"status":"done","summary":"Brief result",
 "artifacts":["/absolute/task/result.txt"],
 "criteria":[{"criterion":"<original acceptance text>","status":"pass",
              "evidence":"/absolute/task/check.txt"}],"open_questions":[]}
```

Use status done/blocked/failed and criterion pass/fail/unverified. Cover every
original criterion exactly once. Artifacts and evidence must be existing files
inside the task directory or checkout (including symlink resolution). A summary
is at most 1200 UTF-8 bytes; at most 12 artifacts and 8 open questions.
`receive <id> --owner <owner> --file <absolute-envelope>` prints only
`task_id`, `state` and the validated envelope (use `show` for the full record).
It rejects stale attempts,
foreign tasks, path escapes and `done` with unverified criteria. Envelope input
must be a regular file: FIFOs, sockets, directories and devices are rejected.
Contained symlinks resolve once; descriptor traversal then refuses symlink
replacements, and a pinned descriptor bounds the read to 16 KiB plus one byte.
Every descriptor closes on rejection, releasing the ledger lock. It records
reviewing, not accepted. Acceptance also needs independent review evidence,
observed model/effort matching the request, and a passing check recorded by an
earlier `check` call (see Ledger operations); file existence proves no quality.

## Model and effort per attempt

For envelope-v1 tasks `tasks.py attempt` requires an explicit `--model` and
`--effort`; an inherited default is not a recorded choice. Start from this
table, approved by the owner on 2026-11-04. It states preferences, not account
availability: validate the installed catalog on every host (`claude --help`,
`codex debug models`) and never pin an obsolete Codex model.

| Work type | Default harness | Claude | Codex |
| --- | --- | --- | --- |
| CoS itself | Claude | opus / high | none |
| Implementation, well specified | Codex | sonnet / medium | gpt-6.1-sol / medium |
| Implementation, ambiguous, multi-file or migration | Codex | opus / high (xhigh over 30 min) | gpt-6-astra / medium, xhigh for exacting work |
| Small edits, extraction | either | haiku / medium | gpt-6-luna / low, raise up to high |
| Review, security | the harness the author did not use | opus / high | gpt-6.1-sol / high |
| Research, many sources | Claude | readers haiku / medium; synthesis opus / high | none |
| Documents, PRDs | Claude | opus / high | none |
| Operations, infrastructure changes | either | opus / high | gpt-6.1-sol / high |
| Daily admin (mail, calendar) | Claude | haiku / medium | none |
| Checkable output (tests, verifier) | either | the row's model at low; re-run failures at high | same |

The Claude column names the 5.5 models by alias. Use fable only after a
capability-sensitive task failed on opus / high, or on the owner's request; its
usage-credit consent prompt can stall an unattended pane for up to 5 minutes,
and the controller never answers that prompt.

Compare cost per solved task when tuning. A bundled model catalog establishes
support, not successful execution.

Pass both values on every route. The flags below are today's launch; with a
ready launch plan the plan argv carries them instead (see "Worker profiles and
launch plans"):

- Agent tool: set `model` (`opus`, `sonnet`, `haiku`) and `effort` from the
  table. The table is the skill's explicit effort instruction for the tool.
- Herdr Claude worker: `-- --model <model> --effort <level>`. Implementation and
  document workers add `--settings ~/.claude/worker-floor/<impl|docs>.json`.
  Implementation workers also add
  `--tools Bash,Read,Edit,Write,Skill,ToolSearch,Agent,AskUserQuestion`. Keep
  `ToolSearch`: without it first-call usage rose by about 72k on pro-dev. Daily
  admin workers add neither.
- Herdr Codex worker: `-- -m <model> -c model_reasoning_effort="<level>"
  -c check_for_update_on_startup=false`. This launch-only update setting keeps
  the owner's interactive update notices; profile workers carry it in their
  own config. It does not bypass workspace or hook trust dialogs: report those
  blocks for the owner to resolve.

Launch workers without `CLAUDE_CODE_EFFORT_LEVEL` in their environment (for
example `env -u CLAUDE_CODE_EFFORT_LEVEL`); it overrides per-worker effort. Do
not change the user's own profile for this. Use argv arrays; never interpolate a
topic into shell code.

Every attempt's `--reason`, including a repair or a reuse of the same worker,
quotes its row in the table above: the Work type and Default harness cells,
copied exactly. When the attempt does not use that row's default harness, or the
profile "Worker profiles and launch plans" gives that work type, the reason also
says why. A row whose default harness is `either` has no default harness to
depart from. For example: `--reason "Research, many sources / Claude; using Codex
because the source exists only there"`.

Record the choice with `attempt --kind ... --model ... --effort ...
--profile <profile> --route <hc|herdr1|agent> [--plan <absolute-launch-plan.json>]
--reason ... --owner ...` (the reason names
the table row and any escalation). Record observed values only from evidence:

- Herdr route (Herdr 1 panes and `hc` terminals): after the worker's first
  turn, run `observe <task-id> --owner <owner> --transcript <log>
  --launch-prompt <prompt>`, passing the exact prompt text the worker was
  launched with. The log is the worker's own session log:
  - Claude: `~/.claude/projects/<cwd-slug>/<session-id>.jsonl`, where the slug
    is the launch directory with every `/` and `.` replaced by `-`. Launching
    with `-- --session-id <new-uuid>` names the file in advance. `observe`
    reads `.message.model` and the top-level `.effort` of each assistant entry
    written since the attempt was reserved, skipping `<synthetic>` and
    sidechain entries.
  - Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<session-id>.jsonl`
    (local date). `observe` reads `.payload.model` and `.payload.effort` of each
    `turn_context` entry written since the attempt was reserved; Codex 0.166+
    rollouts carry no `agent_message` events, and none are needed.

  The log must name its own session (file name, entry `sessionId` or
  `session_meta.id`), must start inside the task directory, and its first user
  message must equal the launch prompt. The last check separates a worker from
  a controller that shares its directory: both logs sit in the same project
  directory and both mention the brief path, but only the worker's log opens
  with the launch prompt. When several candidate logs exist, a refusal naming
  the launch prompt means "not this worker"; try the next candidate.
  `observe` cannot prove that the log was written by the process in the bound
  pane. Two workers launched with the same prompt in the same directory during
  the same attempt are indistinguishable, so give each launch a distinct
  prompt (the task-specific brief path already does).
- Agent-tool route: `attempt --route agent`, then `bind --session
  <returned-native-agent-id>` rather than inventing a pane. A synchronous Agent
  call returns its id only when the worker finishes, so bind and record
  `running` then, with a note saying so. Then run `observe <task-id> --owner <owner> --transcript <path>` on
  `~/.claude/projects/<cwd-slug>/<controller-session>/subagents/agent-<agent-id>.jsonl`.
  It reads the model and effort recorded on every assistant turn.
  The controller files the Agent's returned final text as a task-local report and
  its bounded envelope as a JSON file, preserving criterion verdicts and evidence
  exactly; do not turn missing evidence into a pass. If the worker cannot write
  files, save its returned evidence as task-local files and cite those files in
  the envelope. After binding, explicitly record `running` as above, then `receive
  --file <envelope>` to enter `reviewing`, run and record the independent `check`,
  and accept with its check ID. This uses envelope-v1 on the same reserved attempt;
  no invented pane or new attempt is needed for a synchronous result.

On either route, exactly one (model, effort) pair must appear. No counted
entry, an entry missing its model or effort, and mixed pairs (for example a
model switch mid-session) are refused, and a refusal clears any value an
earlier `observe` recorded, so `accepted` cannot rest on it. A mismatched
file name or a non-regular file is also refused, because these logs are not a
published interface. After a refusal, report the route as unobserved rather
than binding the requested values by hand. `bind --model/--effort` is the
legacy-contract hand-recorded path: `tasks.py` refuses it on every envelope-v1
route, including Agent. Use `observe --transcript <session-log>` and, on terminal
routes, `--launch-prompt <prompt>`. Agent effort comes from the subagent transcript.
`bind --pane` / `--session` without values still works. Only legacy-contract tasks
keep hand-recorded values.

`accepted` requires the observed model to match the request (a Claude alias
matches its full model ID) and the observed effort to equal it. Pass the same
envelope contract in every brief. Do not claim a fake fixture proves a live
dispatch.

## Worker profiles and launch plans

Profiles: implementation/review/operations use `dev` (common+dev); controller
uses `cos`; documents use `writing`; other research/admin uses `common`. Pass the
choice to every `attempt` as `--profile <profile>`; `tasks.py` has no default,
so the ledger always records it. Profiles apply only to workers the controller
launches. A session the owner opens directly keeps the full instruction set.

### Prepare and read the plan

Before each fresh launch, select the harness, profile, model, effort, reason
and route, then prepare a plan with `bin/worker-profile` from a setup
checkout whose `main` matches the applied claude-code cookbook (on pro-dev
`~/ManagedProjects/setup`). Pass those selected values, the task cwd, a new
unique directory under the task directory, and the selected launch route:
`hc` for an hc terminal, `agent` for the Agent tool,
`herdr1` for a Herdr 1 pane. Every flag except `--catalog` is required; without
`--route` the plan always says `launch_ready: false`. Pass the call as an argv
array, never a shell string:

```text
python3 <setup-checkout>/bin/worker-profile prepare --harness <claude|codex> \
  --route <hc|agent|herdr1> --profile <profile> --model <model> \
  --effort <effort> --reason <attempt-reason> \
  --cwd <task-cwd> --directory <task-dir>/plan-<unique-launch-token> \
  [--catalog <task-dir>/codex-models.json]   # Codex: saved `codex debug models` output
```

`prepare` never launches anything. It refuses (exit 1, `{"error": ...}`) when the
deployed profile or Codex home is missing or differs from the rendered source,
and it writes `<task-dir>/plan-<unique-launch-token>/launch-plan.json` otherwise.
The directory identifies a preparation, not an attempt number that has yet to
be reserved. Keep the returned path for retries; never overwrite that directory.
Read that file and use the profile launch below **only when all of these hold**:

- `launch_ready` is exactly `true`;
- `harness`, `route`, `profile`, `model`, `effort` and `cwd` equal the selected values and task;
- `argv[0]` equals `harness`.

An existing preparation directory or a failed attempt reservation is a state
reconciliation problem, not a fallback condition. Follow the retry procedure
in Ledger operations and keep the saved plan. For an unavailable/stale deployed
profile, `launch_ready: false`, or a mismatch in the checks above, keep today's
launch exactly as described in "Launch example" and "Model and effort per
attempt", including the worker-floor settings and the `--tools` allowlist for
implementation workers, and do not call the worker profile-isolated. `launch_ready`
is true for claude×hc, claude×agent and codex×hc (2026-11-08), and claude×herdr1
and codex×herdr1 (2026-11-09 pro-dev canary). Codex on the Agent tool remains
unsupported. Prepare and validate the plan before reserving the attempt, then
pass the same selected values and `--plan <absolute-plan-file>` to `attempt`
only when launching from it. Check the returned attempt against the plan before
creating a pane. Reuse follows the Ledger operations procedure: no preparation,
no new launch, and inheritance of the original plan. Omit `--plan`
on a fresh fallback and record `launch_ready false: default launch` (or the actual
refusal/mismatch) in the `update --state running` note.

### Profile launch per route

Pass `env_set`, `env_unset` and `argv` from the plan unchanged, as argv arrays.
Never build a shell string from them. The route's own additions stay as today
and come after the plan argv: the prompt, then for implementation and document
Claude workers `--settings ~/.claude/worker-floor/<impl|docs>.json`, then for
implementation workers `--tools Bash,Read,Edit,Write,Skill,ToolSearch,Agent,AskUserQuestion`
(last, because it is variadic). The plan argv already carries the model and
effort flags. After the first turn, run `observe --transcript <log>
--launch-prompt <prompt>` as on every Herdr route. The Claude session log
path depends on the cwd, as today. Codex writes rollouts under
`$CODEX_HOME/sessions`, so a profile worker's rollout is under the plan's
`codex_home`, not `~/.codex/sessions`; `observe` accepts it by file name.

- **Herdr 1, Claude or Codex.** Add one `--env <KEY>=<VALUE>` to `pane split`
  per `env_set` entry. Herdr 1 has no unset option (`pane split --help` lists
  only `--env`), so before `agent start` clear `env_unset` in the new pane with
  `herdr pane run <returned-id> unset <NAME> ...`, after checking each name
  against `^[A-Z_][A-Z0-9_]*$`, and wait for its shell prompt. `agent start
  --kind <harness>` runs the canonical executable, so pass `argv[1:]` after
  `--`:

  ```text
  herdr --session <s> pane split --pane <caller> --direction right --cwd <plan.cwd> --no-focus \
    --env <KEY>=<VALUE> [--env ...] [--env COS_...]
  herdr --session <s> pane run <returned-id> unset <env_unset names>
  # Claude:
  herdr --session <s> agent start <reserved-agent-name> --kind claude --pane <returned-id> \
    -- <plan.argv[1:]> <launch-prompt> [route additions]
  herdr --session <s> agent wait <reserved-agent-name> --until working --until blocked --timeout 30000
  ```

  For Codex, run the Codex start step in "Launch example" with `<plan.argv[1:]>`
  in place of its `-m` and `-c` options and the prompt still last. Do not send the
  first prompt with `agent prompt`: "Launch example" explains why. Then start the
  background wait loop from that section.

  The four `COS_*` variables from "Launch example" apply to a profile launch
  under the same condition: a Claude worker and a Herdr 1 controller.

- **Herdr 2 (`hc`), Claude or Codex.** Wrap the plan argv in `/usr/bin/env`, one
  `-u <NAME>` per `env_unset` entry and one `<KEY>=<VALUE>` per `env_set` entry,
  plus the controller's PATH (see `hc-route.md`). `env` resolves `argv[0]`
  through that PATH; confirm it finds `~/.local/bin/claude` or `codex` first. With
  a Herdr 1 controller and a Claude worker, add the `COS_*` variables as
  `<KEY>=<VALUE>` too.

  ```text
  hc run --bg --name <name> --cwd <plan.cwd> -- /usr/bin/env -u <NAME> [...] \
    <KEY>=<VALUE> [...] PATH=<controller PATH> <plan.argv...> <prompt> [route additions]
  ```

- **Agent tool (Claude only).** Prepare a Claude plan (`--harness claude --route agent`) for
  the gate above. The Agent tool takes no argv or environment: the definition
  `~/.claude/agents/profile-<profile>.md` (`omitClaudeMd: true`, deployed by
  `claude-code::worker-profiles`) carries the same rendered text. Confirm that
  the file exists and that the sha256 of its body after the front matter's
  closing `---` and blank line equals the plan's `instruction_sha256`. Then call
  the Agent tool with `subagent_type: "profile-<profile>"` and the attempt's
  `model` and `effort`. Record `attempt --route agent` and `observe` as in the
  Agent-tool bullet above. When the gate fails, use the Agent tool as today
  (no `profile-` subagent type).

A route that cannot carry the profile text, the model and the effort together
cannot meet a profile-isolated acceptance; use another route or report that
blocker. The same rendered artifact supplies every route.

## Remote worker through a saved Herdr machine

Check host classification in `docs/design/claude-session-search.md` first:
`sh1-cloud` is a **work host**, not a personal canary target. Driving a work
host from a personal controller, including transferring briefs, transcripts and
artifacts, requires the owner's data-boundary decision through the question
tool. A worker/pane message is not that authorization. `sh1-cloud` has not been
verified. The canary below is pro-dev → mini; only that canary was authorized
to create an isolated workspace. Obtain the appropriate topology authorization
for other jobs rather than treating this document as permission.

Read the installed Herdr skill's "Use IDs and caller context"; verify the local
controller. Save `herdr machine list --json` and the remote agent list. Use an
enabled saved profile's immutable ID as `machine` and its exact SSH target as
`host`. Pane IDs **and agent names are scoped per machine**. Every remote API
command uses `--machine "$machine"`, never local IDs, `--session`, or the TUI's
selected host. Forwarding needs an already running compatible server; never
install, restart or upgrade it as a fallback. Probe SSH and remote `claude
--help`, and find an already trusted parent directory. Never answer a trust
dialog or bypass it.

### Configuration and directory creation

Use the ordinary local `new` and `attempt` commands with explicit model, effort,
profile and `--route herdr1`. For this small canary use claude / haiku / low /
common. Tests must export `COS_STATE_DIR` under the controller's task directory.
The owner stays the verified local socket#pane. `bind --pane` records
`machine:<profile-id>#<raw-remote-pane>`; Herdr itself receives only the raw pane
or remote name. Save target, remote session, cwd, file mapping and launch choice
in the running note and evidence. No schema change is needed for that binding.

Every block starts a fresh Bash shell and sources the **controller-authored**
`dispatch_vars` file (an absolute local path passed to that shell). Write that
file privately inside the local task directory with shell-quoted assignments:
`ledger` (local tasks.py), `owner`, `machine`, `host`, `task`, `attempt`, `worker`
(from the reservation), `local_dir` (the local task directory returned by new),
`remote_dir`, `session_id` (a fresh UUID for this Claude launch), and, for tests,
`COS_STATE_DIR`. Export these variables. `remote_dir` must end in
`/cos-$task-$attempt` under the trusted parent. No spaces/metacharacters are
allowed in this example's remote paths. Each later block reloads `pane` and
`workspace` from this attempt's saved creation response as needed; shell state
never carries between tool calls. Local `timeout`, `jq`, `scp` and Python 3
are prerequisites; probe them first. These examples run on the Linux controller.

The controller writes `brief-$attempt.md` inside `local_dir`. Its exact contract
requires the worker to write `report-$attempt.txt` and `check-$attempt.txt` inside
`remote_dir`; the envelope refers to those same basenames under **local_dir**,
where the controller will copy them. Include task ID, attempt, original criteria
and envelope-v1 limits. The worker closes the report/evidence first, writes
`envelope-$attempt.tmp`, closes it, then atomically renames it to
`envelope-$attempt.json` in the same directory. Never modify published files.
Do not write the final envelope directly. The worker must not modify `.cos-owner`.
The transfer uses a predeclared finite manifest, never paths from an unvalidated
envelope. Omit local `COS_*` notification instructions from the remote brief;
the remote Stop hook would target the wrong server. The controller wait handles
notification.

```bash
# remote-phase: directory
set -euo pipefail
source "${dispatch_vars:?controller-authored configuration required}"
: "${ledger:?}" "${owner:?}" "${machine:?}" "${host:?}" "${task:?}" "${attempt:?}" "${worker:?}" "${local_dir:?}" "${remote_dir:?}" "${session_id:?}"
[[ "$task" =~ ^[a-f0-9]{16}$ && "$attempt" =~ ^[1-9][0-9]*$ ]]
[[ "$remote_dir" =~ ^/[a-zA-Z0-9_./-]+$ && "$remote_dir" != *..* && "$remote_dir" == */cos-"$task"-"$attempt" ]]
# Exclusive intent survives an ambiguous SSH result. Never blindly repeat it.
python3 -c 'import sys,uuid; f=open(sys.argv[1],"x"); f.write(uuid.uuid4().hex); f.close()' "$local_dir/remote-$attempt.token"
token=$(cat "$local_dir/remote-$attempt.token")
timeout --kill-after=2s 15s ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$host" "umask 077; mkdir -m 700 '$remote_dir' && printf '%s' '$token' > '$remote_dir/.cos-owner'"
```

If directory creation fails, stop. Do not adopt a pre-existing directory or
manufacture a marker. After an ambiguous result inspect the remote directory
and marker against the saved token before recovery. Profile preparation comes
**after** directory creation. Run remote `worker-profile prepare` with this
remote cwd and a plan directory inside it. Validate a remote plan's cwd against
`remote_dir` (not the local ledger cwd); validate its other fields as in "Worker
profiles and launch plans", copy the plan back, and record `--plan` when used.
Missing/stale profiles use the documented default-launch fallback with its
reason saved in the ledger. The ready remote plan path is **not live-verified**;
the mini canary uses the default fallback. Do not claim profile isolation from
that canary. The following blocks show the fallback for the small common task;
implementation/document tasks still need their worker-floor route additions.

### Workspace and launch

```bash
# remote-phase: workspace
set -euo pipefail
source "${dispatch_vars:?}"
: "${local_dir:?}" "${attempt:?}" "${remote_dir:?}" "${machine:?}" "${host:?}" "${worker:?}" "${ledger:?}" "${task:?}" "${owner:?}"
# Refuse both a recorded workspace and an ambiguous earlier create.
[ ! -e "$local_dir/create-$attempt.json" ]
[ ! -L "$local_dir/create-$attempt.json" ]
python3 -c 'import sys; open(sys.argv[1],"x").close()' "$local_dir/create-$attempt.intent"
herdr --machine "$machine" agent list > "$local_dir/agents-before-$attempt.json"
scp "$local_dir/brief-$attempt.md" "$host:$remote_dir/brief-$attempt.md"
herdr --machine "$machine" workspace create --cwd "$remote_dir" --label "$worker" --no-focus > "$local_dir/create-$attempt.json"
pane=$(jq -er '.result.root_pane.pane_id | select(type == "string" and length > 0)' "$local_dir/create-$attempt.json")
workspace=$(jq -er '.result.workspace.workspace_id | select(type == "string" and length > 0)' "$local_dir/create-$attempt.json")
python3 "$ledger" bind "$task" --owner "$owner" --pane "machine:$machine#$pane" > "$local_dir/bind-$attempt.json"
herdr --machine "$machine" pane run "$pane" 'unset CLAUDE_CODE_EFFORT_LEVEL COS_WORKER_TASK_ID COS_WORKER_ATTEMPT COS_CONTROLLER_PANE COS_CONTROLLER_SESSION COS_STATE_DIR'
herdr --machine "$machine" pane process-info --pane "$pane" > "$local_dir/shell-$attempt.json"
```

Read the shell evidence: its foreground must be the interactive shell. Re-probe
until ready. Any create error is ambiguous: inspect topology, never retry create
blindly or erase its intent file. The common Claude/Codex start step in "Launch
example" applies remotely by replacing **every** `--session "$s"` with
`--machine "$machine"`. Keep its harness-specific argv, including Codex update
suppression. This Claude canary concurrently observes the newly created raw pane
because a short first turn can finish before start returns ready.

```bash
# remote-phase: launch
set -euo pipefail
source "${dispatch_vars:?}"
: "${local_dir:?}" "${attempt:?}" "${machine:?}" "${worker:?}" "${remote_dir:?}" "${session_id:?}"
pane=$(jq -er '.result.root_pane.pane_id | select(type == "string" and length > 0)' "$local_dir/create-$attempt.json")
python3 -c 'import sys; open(sys.argv[1],"x").close()' "$local_dir/launch-$attempt.intent"
launch_prompt="Read $remote_dir/brief-$attempt.md and execute that brief exactly."
herdr --machine "$machine" agent start "$worker" --kind claude --pane "$pane" -- --model haiku --effort low --session-id "$session_id" "$launch_prompt" > "$local_dir/start-$attempt.json" 2> "$local_dir/start-$attempt.err" &
start_pid=$!
activity=unobserved; deadline=$((SECONDS+60))
while [ $SECONDS -lt $deadline ]; do
  if timeout --kill-after=2s 5s herdr --machine "$machine" agent wait "$pane" --until working --until blocked --timeout 1000 > "$local_dir/activity-$attempt.json" 2> "$local_dir/activity-$attempt.err"; then
    activity=observed; break
  fi
  sleep 1
done
if wait "$start_pid"; then start_rc=0; else start_rc=$?; fi
printf 'start_rc=%s activity=%s\n' "$start_rc" "$activity"
herdr --machine "$machine" agent get "$worker" > "$local_dir/identity-$attempt.json"
[ "$start_rc" = 0 ] && [ "$activity" = observed ]
```

Read the actual activity state and identity. A nonzero result is ambiguous
delivery, not permission to restart. For start timeout/name loss use the common
step's **recovery loop only**, with remote prefix and raw pane: get the name,
restore it by rename if lost, then observe working/blocked. Do not send start
again. The saved concurrent observation can prove a short first turn. Blocked
means report the dialog, never answer it. Remote Codex, name recovery and the
ready remote plan route remain **not live-verified** by this canary.

Record `update --state running --note ... --evidence <activity-file>` only after
observed execution; the note includes the machine/target/session/remote cwd and
fallback reason. Run this next block in the controller's background. The SSH
check has a 15-second wall-clock limit (plus at most 2 seconds before SIGKILL),
not merely a connection timeout. With the bounded API calls, the ten-minute
outer deadline can overrun by at most one iteration, not hang on a sleeping host.

```bash
# remote-phase: wait
set -euo pipefail
source "${dispatch_vars:?}"
: "${host:?}" "${remote_dir:?}" "${attempt:?}" "${machine:?}" "${worker:?}" "${local_dir:?}"
[[ "$remote_dir" =~ ^/[a-zA-Z0-9_./-]+$ && "$remote_dir" != *..* ]]
end=$((SECONDS+600)); why=timeout
while [ $SECONDS -lt $end ]; do
  if timeout --kill-after=2s 15s ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$host" "test -f '$remote_dir/envelope-$attempt.json'"; then rc=0; else rc=$?; fi
  if [ "$rc" = 0 ]; then why=envelope; break; fi
  if [ "$rc" != 1 ]; then why=transport; break; fi
  if ! timeout --kill-after=2s 15s herdr --machine "$machine" agent get "$worker" > "$local_dir/poll-$attempt.json" 2> "$local_dir/poll-$attempt.err"; then why=gone; break; fi
  if timeout --kill-after=2s 20s herdr --machine "$machine" agent wait "$worker" --until blocked --timeout 15000 > "$local_dir/wait-$attempt.json" 2> "$local_dir/wait-$attempt.err"; then why=blocked; break; fi
done
printf 'reason=%s\n' "$why"
```

`envelope`: transfer below. `blocked`: get/read the remote dialog, report it and
re-arm after the owner resolves it. `gone` is only a candidate: repeat the file
check, get and pane inspection; a socket failure is transport, not disappearance.
`transport` (including exit 124/137 from timeout): save errors, check connectivity
and reconcile state before retry. `timeout`: inspect progress and re-arm. Always
recheck the envelope before declaring failure. Failed wait alone is not completion.
The file-absent polling path and envelope outcome are live-verified on mini.
The blocked, gone and transport branches are **not live-verified**. Synthetic
regressions do not change that designation.

### Receipt, observation and acceptance

Only after `reason=envelope`, transfer the fixed manifest. Each attempt has new
basenames and an exclusive staging directory. Hard-link publication refuses
existing landing files (including symlinks), so a retry cannot overwrite evidence.
On a partial transfer/publication, stop and inspect; do not rerun this block or
delete the prior files. Reconcile that attempt explicitly or reserve a new attempt
with a new directory and file names. Copy the unmodified session log with the UUID
used at launch. Fetch artifacts before any cleanup.

```bash
# remote-phase: receive
set -euo pipefail
source "${dispatch_vars:?}"
: "${local_dir:?}" "${attempt:?}" "${host:?}" "${remote_dir:?}" "${session_id:?}" "${ledger:?}" "${task:?}" "${owner:?}"
[[ "$session_id" =~ ^[a-f0-9-]{36}$ ]]
for name in "report-$attempt.txt" "check-$attempt.txt" "envelope-$attempt.json" "$session_id.jsonl"; do
  [ ! -e "$local_dir/$name" ]
  [ ! -L "$local_dir/$name" ]
done
landing="$local_dir/landing-$attempt"
mkdir -m 700 "$landing"
for name in "report-$attempt.txt" "check-$attempt.txt" "envelope-$attempt.json"; do
  scp "$host:$remote_dir/$name" "$landing/$name"
done
slug=${remote_dir//\//-}; slug=${slug//./-}
scp "$host:.claude/projects/$slug/$session_id.jsonl" "$landing/$session_id.jsonl"
for name in "report-$attempt.txt" "check-$attempt.txt" "$session_id.jsonl" "envelope-$attempt.json"; do
  ln -T "$landing/$name" "$local_dir/$name"
done
python3 "$ledger" receive "$task" --owner "$owner" --file "$local_dir/envelope-$attempt.json" > "$local_dir/receive-$attempt.json"
launch_prompt="Read $remote_dir/brief-$attempt.md and execute that brief exactly."
python3 "$ledger" observe "$task" --owner "$owner" --transcript "$local_dir/$session_id.jsonl" --launch-prompt "$launch_prompt" --remote-cwd "$remote_dir" > "$local_dir/observe-$attempt.json"
```

`--remote-cwd` is an explicit assertion by the controller, not host authentication.
It requires a machine-qualified herdr1 binding and a normalized absolute POSIX
path, and compares the transcript's starting cwd **exactly**, without resolving
it on the local filesystem. Session ID, first prompt, attempt time, model/effort
and all other transcript checks remain in force. A mismatch refuses observation
and clears an older remote observation. Envelope/artifact containment still uses
the local task directory. Do not rewrite the raw log to make it pass.

Receive enters reviewing. Independently review every criterion and run the task's
checks, saving their output in `independent-$attempt.txt`; do not turn file
existence into a passing review. Set `check_exit` to that real check exit status
in the controller configuration, then record it:

```bash
# remote-phase: check
set -euo pipefail
source "${dispatch_vars:?}"
: "${ledger:?}" "${task:?}" "${owner:?}" "${local_dir:?}" "${attempt:?}" "${check_exit:?}"
python3 "$ledger" check "$task" --owner "$owner" --file "$local_dir/independent-$attempt.txt" --exit-status "$check_exit" --note 'Independent criterion review' > "$local_dir/check-record-$attempt.json"
```

Read the saved independent check, observed model/effort and returned check ID.
Only a passing independent check and criterion-by-criterion acceptance justify
this next, separate call. A failure uses the normal retry or needs-user path;
keep the worker available for correction.

```bash
# remote-phase: accept
set -euo pipefail
source "${dispatch_vars:?}"
: "${ledger:?}" "${task:?}" "${owner:?}" "${local_dir:?}" "${attempt:?}"
check_id=$(jq -er '.check.id' "$local_dir/check-record-$attempt.json")
python3 "$ledger" update "$task" --owner "$owner" --state accepted --check "$check_id" --note 'All original criteria independently verified' --evidence "$local_dir/independent-$attempt.txt" > "$local_dir/accepted-$attempt.json"
```

### Cleanup after acceptance

Retain the remote artifact directory until acceptance; the settled-pane lifecycle
above still applies. The local `closable` command deliberately skips remote
panes: inspect ownership and live state on the selected machine instead.
The following legacy teardown block is for a recorded workspace that still
exists after pane cleanup. If closing its last pane already removed that
workspace, prove absence with a successful complete remote workspace inventory
and omit the workspace-close line; a failed socket request is not absence.
Never run workspace close while any contained agent is working or unrecorded.
The block checks the ledger's actual accepted state, closes only the recorded
workspace, and only then removes the directory whose creation token matches.
Any failure stops before subsequent actions. A close timeout needs reconciliation,
not blind repetition. Compare pre-existing agents by pane/terminal/name (their
status may legitimately advance), and save absence probes afterwards.

```bash
# remote-phase: cleanup
set -euo pipefail
source "${dispatch_vars:?}"
: "${ledger:?}" "${task:?}" "${owner:?}" "${attempt:?}" "${local_dir:?}" "${remote_dir:?}" "${machine:?}" "${host:?}"
[[ "$task" =~ ^[a-f0-9]{16}$ && "$attempt" =~ ^[1-9][0-9]*$ ]]
[[ "$remote_dir" =~ ^/[a-zA-Z0-9_./-]+$ && "$remote_dir" != *..* && "$remote_dir" == */cos-"$task"-"$attempt" ]]
workspace=$(jq -er '.result.workspace.workspace_id | select(type == "string" and length > 0)' "$local_dir/create-$attempt.json")
token=$(cat "$local_dir/remote-$attempt.token")
[[ "$token" =~ ^[a-f0-9]{32}$ ]]
python3 "$ledger" show "$task" > "$local_dir/pre-cleanup-$attempt.json"
jq -e '.task.state == "accepted"' "$local_dir/pre-cleanup-$attempt.json"
herdr --machine "$machine" workspace close "$workspace" > "$local_dir/close-$attempt.json"
timeout --kill-after=2s 15s ssh -n "$host" "test ! -L '$remote_dir' && test -f '$remote_dir/.cos-owner' && test ! -L '$remote_dir/.cos-owner' && test \"\$(cat '$remote_dir/.cos-owner')\" = '$token' && rm -rf -- '$remote_dir' && test ! -e '$remote_dir'"
herdr --machine "$machine" agent list > "$local_dir/agents-after-$attempt.json"
herdr --machine "$machine" pane list > "$local_dir/panes-after-$attempt.json"
```
