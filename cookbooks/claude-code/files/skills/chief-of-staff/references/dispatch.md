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
python3 <skill-dir>/scripts/tasks.py attempt <task-id> \
  --kind codex --model default --reason <routing-or-repair-reason>
python3 <skill-dir>/scripts/tasks.py bind <task-id> --pane <returned-pane-id>
python3 <skill-dir>/scripts/tasks.py update <task-id> --state running \
  --note <observed-start> --evidence <observed-working-transition>
python3 <skill-dir>/scripts/tasks.py update <task-id> --state reviewing \
  --note <result-received> --evidence <result-location>
python3 <skill-dir>/scripts/tasks.py update <task-id> --state accepted \
  --note <criterion-by-criterion-verdict> --evidence <independent-check>
python3 <skill-dir>/scripts/tasks.py reported <task-id> --note <message-sent>
python3 <skill-dir>/scripts/tasks.py list --owner <socket#controller-pane>
python3 <skill-dir>/scripts/tasks.py show <task-id>
```

`attempt` reserves the next attempt and a unique Herdr name before any mutation.
For a correction to the same settled worker, pass `--reuse-agent` with the same
kind/model: this consumes an attempt but retains its live name. Re-bind its
verified existing pane, skip `agent start`, and prompt that existing name only
after confirming it is ready. Changing harness/model uses a fresh worker.
Keep the JSON output: it includes `agent` and `attempt`. Save the full worker
brief to a private task-local file under the returned task directory using a
file-write tool. It is a controller handoff record, not a requirement for the
worker to write its answer to a file. `bind` records the returned pane before
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
herdr pane layout --current
herdr pane split --current --direction right --cwd <task-cwd> --no-focus
herdr agent start <reserved-agent-name> --kind codex --pane <returned-id>
herdr agent prompt <reserved-agent-name> <brief-text> --wait --timeout 30000
herdr agent get <reserved-agent-name>
herdr agent read <reserved-agent-name> --source recent-unwrapped --lines 200
herdr agent wait <reserved-agent-name> --timeout 30000
```

For explicit model selection, append native options **after** `--`, e.g.
`-- --model <verified-model>`, and record the resulting effective model/effort.
Update the attempt's observed model with `bind --pane <id> --model <actual-model>`.
Wait for an actual shell/agent prompt rather than a fixed startup sleep. Do not
prompt a working agent or send slash commands as if they were normal task text.
Read up to 1000 lines for missing results; only if that fails, ask the worker to
save its full answer in a temporary file and read it locally (Herdr skill rule).

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
authorization. Report the result, artifact/commit links, checks and their actual
outputs, and remaining failures/risks. Leave the terminal ready for review.
```
