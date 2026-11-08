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
python3 <skill-dir>/scripts/tasks.py new --owner <socket#controller-pane> \
  --topic <topic> --cwd <absolute-dir> --scope <authorized-scope> \
  --acceptance <criterion> [--acceptance <criterion> ...]
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
Reused workers inherit their previous plan, including null; an explicitly
supplied different plan is refused because reuse does not launch a new process.

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
Re-bind its
verified existing pane, skip `agent start`, and prompt that existing name only
after confirming it is ready. Changing harness/model uses a fresh worker.
Keep the JSON output: it includes `agent` and `attempt`. Save the full worker
brief to a private task-local file under the returned task directory using a
file-write tool. It is the controller handoff record. For envelope-v1 tasks the worker must
write the full answer and test evidence as task-local or checkout artifacts,
then return only the bounded envelope. `bind` records the returned pane before
`agent start`; if an interrupted split has no recorded ID, inspect topology
and refuse to guess or blindly create another pane.

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

## Launch example

These are shapes, not commands to paste with placeholder IDs. Use actual JSON
IDs and pass shell arguments with a file-based subprocess argv list or correct
shell quoting; user topics are data, never shell commands.

```text
herdr --session <verified-session> pane layout --pane <verified-caller-pane>
herdr --session <verified-session> pane split --pane <verified-caller-pane> --direction right --cwd <task-cwd> --no-focus \
  [--env COS_WORKER_TASK_ID=<task-id> --env COS_WORKER_ATTEMPT=<attempt> \
   --env COS_CONTROLLER_PANE=<verified-caller-pane> --env COS_CONTROLLER_SESSION=<verified-session>]
# Claude. For Codex use the start step below instead of these two lines.
herdr --session <verified-session> agent start <reserved-agent-name> --kind claude --pane <returned-id> -- <launch-prompt>
herdr --session <verified-session> agent wait <reserved-agent-name> --until working --until blocked --timeout 30000
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

Codex needs its own start step, because `agent start` with a first prompt can
return `timeout` or `agent_name_not_found` while Codex keeps working. Set `s`,
`worker`, `pane`, `model`, `effort` and `launch_prompt` first. The step accepts
those errors only when the wait that follows observes `working` or `blocked`. If
the name is lost, it restores it through the pane and checks again:

```bash
herdr --session "$s" agent start "$worker" --kind codex --pane "$pane" -- \
  -m "$model" -c model_reasoning_effort="$effort" "$launch_prompt" || true
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
not launch again: the first Codex may still be running.

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

## Worker brief

Write a real brief, replacing the fields below; include the user's words where
wording matters. Do not send the controller's entire private conversation.
Every brief states the envelope limits and the spec-conflict rule in the
template below. `receive` rejects an envelope over a limit, so a brief that
omits them invites a rejected report (one brief left out the 12-artifact limit
and its worker returned 20). A brief that says "exactly these changes" can
still name something a check rejects, so the worker needs the stop rule.

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
Acceptance criteria: <observable, individually checkable criteria>
Existing work / previous attempt: <artifact paths, failed criteria and evidence>
Controller pane: <verified controller pane ID, socket and session from the caller helper>
Herdr route for notifying the controller: <Herdr 1 (`herdr`) or Herdr 2 (`hc`), chosen from where the controller pane lives>
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

Close what you open: close every pane you created yourself for this task
(helper shells, test or log panes) as soon as you no longer need it, after
reading anything you still need from it. Close only panes you created, never
the controller pane and never your own worker pane (the controller closes that
after acceptance, because a correction may still need it).

Complete the authorized work and perform the relevant checks. Distinguish facts
from assumptions; report concrete blockers rather than answering permission
dialogs on behalf of the user. Preserve other agents' changes. Do not weaken
the acceptance criteria. Do not send messages to third parties without explicit
authorization. Write full results and actual check output to artifact files inside the supplied
task directory or checkout. Write the envelope below to
`<task directory>/envelope-<n>.json` (at most 16 KiB) and return only that.
Envelope limits: at most 12 artifacts; at most 8 open questions, each at most
600 UTF-8 bytes; summary at most 1200 UTF-8 bytes. Cite a directory or log file
instead of listing more than 12 paths.
If the specification cannot pass a required check (a lint, test or validator
rejects what the brief asks for), stop. Report status `blocked` with the failing
check, its output file, and the specification change it needs. Never deviate
from the specification silently, even to make the check pass.
Do not paste full logs or documents into the controller response. Leave the
terminal ready for review.
```


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
- Herdr Codex worker: `-- -m <model> -c model_reasoning_effort="<level>"`.

Launch workers without `CLAUDE_CODE_EFFORT_LEVEL` in their environment (for
example `env -u CLAUDE_CODE_EFFORT_LEVEL`); it overrides per-worker effort. Do
not change the user's own profile for this. Use argv arrays; never interpolate a
topic into shell code.

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

On either route, exactly one (model, effort) pair must appear. No counted
entry, an entry missing its model or effort, and mixed pairs (for example a
model switch mid-session) are refused, and a refusal clears any value an
earlier `observe` recorded, so `accepted` cannot rest on it. A mismatched
file name or a non-regular file is also refused, because these logs are not a
published interface. After a refusal, report the route as unobserved rather
than binding the requested values by hand. `bind --model/--effort` is the
legacy hand-recorded path: `tasks.py` refuses it for an envelope-v1 task whose
current attempt uses the Herdr route and points to `observe --transcript
<session-log> --launch-prompt <prompt>`. `bind --pane` / `--session` without
values still works there, and legacy-contract tasks and Agent-route attempts
keep the old behaviour.

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
    --env <KEY>=<VALUE> [--env ...]
  herdr --session <s> pane run <returned-id> unset <env_unset names>
  herdr --session <s> agent start <reserved-agent-name> --kind <plan.harness> --pane <returned-id> \
    -- <plan.argv[1:]> [route additions without the prompt]
  herdr --session <s> agent prompt <reserved-agent-name> <brief-text> --wait --timeout 30000
  ```

- **Herdr 2 (`hc`), Claude or Codex.** Wrap the plan argv in `/usr/bin/env`, one
  `-u <NAME>` per `env_unset` entry and one `<KEY>=<VALUE>` per `env_set` entry,
  plus the controller's PATH (see `hc-route.md`). `env` resolves `argv[0]`
  through that PATH; confirm it finds `~/.local/bin/claude` or `codex` first.

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
