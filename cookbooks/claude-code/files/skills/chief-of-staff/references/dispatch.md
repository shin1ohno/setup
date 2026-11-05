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
python3 <skill-dir>/scripts/tasks.py bind <task-id> --pane <returned-pane-id>
python3 <skill-dir>/scripts/tasks.py update <task-id> --state running \
  --note <observed-start> --evidence <observed-working-transition>
python3 <skill-dir>/scripts/tasks.py update <task-id> --state reviewing \
  --note <result-received> --evidence <result-location>
python3 <skill-dir>/scripts/tasks.py update <task-id> --state accepted \
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

For explicit model selection, append native options **after** `--`, e.g.
`-- --model <verified-model>`, and record the resulting effective model/effort.
Update the attempt's observed model with `bind --pane <id> --model <actual-model>`.
Wait for an actual shell/agent prompt rather than a fixed startup sleep. Do not
prompt a working agent or send slash commands as if they were normal task text.
For envelope-v1 tasks do not escalate to full pane history. Request the missing
envelope or delegate an artifact read. The installed Herdr skill's legacy
file-output fallback remains the rule for old tasks; the new explicit artifact
contract is an opt-in protocol, not a reason to alter an active legacy session.
Review the two skill contracts together before deployment. No installed skill
or live controller ledger is changed by adopting this source proposal.

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
foreign tasks, path escapes and `done` with unverified criteria. It records
reviewing, not accepted. Acceptance also needs independent review evidence and
observed model/effort matching the request; file existence proves no quality.

## Explicit selection per attempt (SH1-84)

These owner-selected starting points are preferences, not an account-availability
claim. Validate the installed catalog/help on every host. Labels such as Opus
5.5 must be resolved to a supported CLI alias or model ID before launch.

| Work type | Claude preference | Codex preference |
| --- | --- | --- |
| CoS | Opus 5.5 / high | no default |
| Specified implementation | Sonnet 5.5 / medium | gpt-6.1-sol / medium |
| Ambiguous implementation or migration | Opus 5.5 / high | gpt-6-astra / medium |
| Small edit or extraction | Haiku 5.5 / medium | gpt-6-luna / low, increase when needed |
| Review or security | Opus 5.5 / high | gpt-6.1-sol / high |
| Research | Haiku 5.5 / medium readers; Opus 5.5 / high synthesis | choose only when its tools are needed |
| Documents or PRDs | Opus 5.5 / high | choose for a concrete capability need |
| Infrastructure operations | Opus 5.5 / high | gpt-6.1-sol / high |
| Daily administration | Haiku 5.5 / medium | choose only when its tools are needed |
| Independently checkable verifier | row model / low; failed cases / high | same |

Tune effort before changing model. Skipped files/tests call for more effort;
wrong reasoning with complete context calls for a stronger model. Change one
variable at a time and compare cost per solved task. Cheap workers fit
independent fan-out or work beyond one context, not automatic serial delegation.
Use xhigh/max only beyond 30 minutes or with evaluation evidence. Group parallel
work by model/effort to preserve caches. Fable requires a failed Opus-high
capability case or an explicit owner request; never answer usage-credit consent.

Record `attempt --kind ... --model ... --effort ... --profile dev --route herdr
--reason ... --owner ...`. Unset inherited `CLAUDE_CODE_EFFORT_LEVEL` in the
worker environment, not the user's profile. Pass native Claude `--model MODEL
--effort LEVEL`, or Codex `-m MODEL -c model_reasoning_effort="LEVEL"`, after
Herdr's `--`. Use argv arrays, never interpolate a topic into shell code.
`bind --model ACTUAL --effort ACTUAL` records observed values only after startup
evidence. A bundled model catalog establishes support, not successful execution.

For an authorized cloud Agent-tool route, reserve `--route agent` and bind
`--session <returned-native-agent-id>` rather than inventing a pane. Pass the
native tool's supported model and effort fields explicitly, along with the same
profile text and envelope contract. A tool lacking effort or instruction
isolation cannot meet this route's acceptance; use a supported route or report
that blocker. Do not claim a fake fixture proves a live dispatch.

Profiles: implementation/review/operations use common+dev; controller uses
common+cos; documents use common+writing; other research/admin uses common.
The same rendered artifact supplies both routes. The profile launcher proposal
is reviewed separately; until isolation and login are observed, keep existing
launches unchanged and do not label them profile-isolated.
