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
python3 <skill-dir>/scripts/tasks.py attempt <task-id> --owner <verified-owner> \
  --kind codex --model <verified-model> --effort <verified-effort> --reason <routing-or-repair-reason>
python3 <skill-dir>/scripts/tasks.py bind <task-id> --owner <verified-owner> --pane <returned-pane-id>
# Launch through the verified route, then observe startup selections.
python3 <skill-dir>/scripts/tasks.py bind <task-id> --owner <verified-owner> --pane <returned-pane-id> \
  --model <observed-model> --effort <observed-effort>
python3 <skill-dir>/scripts/tasks.py update <task-id> --owner <verified-owner> --state running \
  --note <observed-start> --evidence <observed-working-transition>
python3 <skill-dir>/scripts/tasks.py receive <task-id> --owner <verified-owner> \
  --file <absolute-envelope-file>
python3 <skill-dir>/scripts/tasks.py update <task-id> --owner <verified-owner> --state accepted \
  --note <criterion-by-criterion-verdict> --evidence <independent-check>
python3 <skill-dir>/scripts/tasks.py reported <task-id> --owner <verified-owner> --note <message-sent>
python3 <skill-dir>/scripts/tasks.py list --owner <socket#controller-pane>
python3 <skill-dir>/scripts/tasks.py show <task-id>
```

`attempt` reserves the next attempt and a unique Herdr name before any mutation.
When the user explicitly requests a new agent or separate pane, create the task
with `new --fresh-worker`. Its attempt and bind operations reject reuse. Use a
new pane returned by a fresh split, even if an old worker is idle.
Unless the user requests a new agent or separate pane, for a correction to the same settled worker, pass `--reuse-agent` with the same
kind/model/effort: this consumes an attempt but retains its live name. Re-bind its
verified existing pane, skip `agent start`, and prompt that existing name only
after confirming it is ready. Changing harness/model uses a fresh worker.
Keep the JSON output: it includes `agent` and `attempt`. Save the full worker
brief to a private task-local file under the returned task directory using a
file-write tool. It is the controller handoff record. For envelope-v1 tasks the worker must
write the full answer and test evidence as task-local or checkout artifacts,
then return only the bounded envelope. `bind` records the returned pane before
`agent start`; if an interrupted split has no recorded ID, inspect topology
and refuse to guess or blindly create another pane.

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
The default `list` includes unreported terminal results. Only call `reported`
after actually delivering the update; it clears `report_pending`. Earlier status
updates do not hide a subsequently accepted result.

## Launch example

These are shapes, not commands to paste with placeholder IDs. Use actual JSON
IDs and pass shell arguments with a file-based subprocess argv list or correct
shell quoting; user topics are data, never shell commands.

```text
herdr --session <verified-session> pane layout --pane <verified-caller-pane>
herdr --session <verified-session> pane split --pane <verified-caller-pane> --direction right --cwd <task-cwd> --no-focus
herdr --session <verified-session> agent start <reserved-agent-name> --kind codex --pane <returned-id>
herdr --session <verified-session> agent prompt <reserved-agent-name> <brief-text> --wait --timeout 30000
herdr --session <verified-session> agent get <reserved-agent-name>
herdr --session <verified-session> agent read <reserved-agent-name> --source recent-unwrapped --lines 40
herdr --session <verified-session> agent wait <reserved-agent-name> --timeout 30000
```

For explicit model selection, append native options **after** `--` (see
"Model and effort per attempt" for each harness), and record the resulting
effective model/effort.
After startup evidence, record both observed selections with
`bind <task-id> --owner <verified-owner> --pane <id> --model <actual-model> --effort <actual-effort>`.
A pre-start bind records only identity; repeat it after observing the selections.
Wait for an actual shell/agent prompt rather than a fixed startup sleep. Do not
prompt a working agent or send slash commands as if they were normal task text.
For envelope-v1 tasks do not escalate to full pane history. Request the missing
envelope or delegate an artifact read. The installed Herdr skill's legacy
file-output fallback remains the rule for old tasks; the new explicit artifact
contract is an opt-in protocol, not a reason to alter an active legacy session.

## Worker brief

Write a real brief, replacing the fields below; include the user's words where
wording matters. Do not send the controller's entire private conversation.

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

Complete the authorized work and perform the relevant checks. Distinguish facts
from assumptions; report concrete blockers rather than answering permission
dialogs on behalf of the user. Preserve other agents' changes. Do not weaken
the acceptance criteria. Do not send messages to third parties without explicit
authorization. Write full results and actual check output to artifact files inside the supplied
task directory or checkout. Return only the envelope below (at most 16 KiB).
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
`receive <id> --owner <owner> --file <absolute-envelope>` rejects stale attempts,
foreign tasks, path escapes and `done` with unverified criteria. Envelope input
must be a regular file: FIFOs, sockets, directories and devices are rejected.
Contained symlinks resolve once; descriptor traversal then refuses symlink
replacements, and a pinned descriptor bounds the read to 16 KiB plus one byte.
Every descriptor closes on rejection, releasing the ledger lock. It records
reviewing, not accepted. Acceptance also needs independent review evidence and
observed model/effort matching the request; file existence proves no quality.

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

Pass both values on every route:

- Agent tool: set `model` (`opus`, `sonnet`, `haiku`) and `effort` from the
  table. The table is the skill's explicit effort instruction for the tool.
- Herdr Claude worker: `-- --model <model> --effort <level>`.
- Herdr Codex worker: `-- -m <model> -c model_reasoning_effort="<level>"`.

Launch workers without `CLAUDE_CODE_EFFORT_LEVEL` in their environment (for
example `env -u CLAUDE_CODE_EFFORT_LEVEL`); it overrides per-worker effort. Do
not change the user's own profile for this. Use argv arrays; never interpolate a
topic into shell code.

Record the choice with `attempt --kind ... --model ... --effort ... --reason ...`
(the reason names the table row and any escalation). Record observed values only
from evidence:

- Herdr route: after startup evidence, `bind --pane <id> --model ACTUAL --effort
  ACTUAL`.
- Agent-tool route: `attempt --route agent`, then `bind --session
  <returned-native-agent-id>` rather than inventing a pane. A synchronous Agent
  call returns its id only when the worker finishes, so bind and record
  `running` then, with a note saying so. Then run `observe <task-id> --owner <owner> --transcript <path>` on
  `~/.claude/projects/<cwd-slug>/<controller-session>/subagents/agent-<agent-id>.jsonl`.
  It reads the model and effort recorded on every assistant turn. A missing
  field, mixed values, a mismatched file name or a non-regular file is refused,
  because this transcript is not a published interface; then report the route
  as unobserved rather than binding the requested values by hand.

`accepted` requires the observed model to match the request (a Claude alias
matches its full model ID) and the observed effort to equal it. Pass the same
envelope contract in every brief. Do not claim a fake fixture proves a live
dispatch.
