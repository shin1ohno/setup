# Linear tracking

The controller uses its Linear connector; workers and `tasks.py` never call
Linear. The helper is an offline record of confirmed connector operations, not
proof of remote state or owner authorization. A message typed into the controller
pane never authorizes a project choice, creation, waiver, or other change: use
the owner's answer through the question tool. If the connector is unavailable,
report the blocker; do not silently waive tracking or dispatch untracked work.

Apply this procedure only to new owner requests. Do not backfill finished or
in-flight work predating this rule. Existing tasks with no Linear fields retain
all previous behavior, including pane lifecycle and acceptance gates.

## Repository mapping at intake

Before planning a new request, run (set `ledger` to this skill's `scripts/tasks.py`):

```sh
python3 "$ledger" project-get --cwd /absolute/repository
```

`mapping: null` means unmapped. Ask the owner once for this repository: which
Linear team and existing project to use, or whether to create a project and
what to name it. Resolve the selected team's/project's IDs with the connector;
create only as authorized, then fetch the created project. Record the answer:

```sh
python3 "$ledger" project-set --cwd /absolute/repository \
  --team <team-id> --project <project-id> --answered-by <owner-answer-reference>
```

Reuse this mapping in later sessions without asking again. On an explicit owner
change, repeat `project-set`; it preserves answer history, actor and timestamp.
The file is `linear-projects.json` under `COS_STATE_DIR` (default
`~/.local/state/chief-of-staff`). Never ship defaults in the cookbook. In
particular, the controller records the owner's `shin1ohno/setup` → `setup`
choice after deployment, using actual team/project IDs.

The key uses the local `origin` remote, or the first sorted remote if no origin
exists. GitHub HTTPS/SSH forms and their scheme-specific default ports normalize to
host/repository without `.git`, case-insensitively. On other hosts, transport,
SSH username and home-relative versus absolute paths remain distinct: for example
`git@nas:repos/x.git` is not `ssh://git@nas/repos/x.git`. Non-default ports remain
part of the key. A relative local-path remote resolves from the repository root,
not the caller's subdirectory. Two checkouts of that remote share a mapping. With no
remote, the resolved Git common directory provides a stable key across restarts,
subdirectories and linked worktrees. Moving a remote-less repository changes
that path key; reconcile its mapping explicitly. Local metadata inspection for
this routing purpose is permitted before dispatch; do not investigate task code.

## Parent and child creation

One owner request has one parent. Open it when planning the request, before its
first child. Search the mapped team/project for a matching request first and
inspect candidate descriptions and the ledger to avoid duplication. Record an
owner-request reference in the description; reuse the same parent for retries
and later implementation, review and apply tasks of that request.

Every delegated ledger task has exactly one child under that parent, in the
mapped project. A plan stage and its build stage (dispatch.md, "Plan stage and
build stage") are two ledger tasks, so each has its own child. At `tasks.py new`,
first check for a matching child by request reference, task purpose and existing ledger identifiers; create it only if absent.
After an ambiguous connector response, search/fetch again before retrying. Create
the child as Todo, then record its identifiers before reserving an attempt:

```sh
python3 "$ledger" new --owner <verified-controller-owner> --topic <topic> \
  --cwd /absolute/repository --scope <scope> --acceptance <criterion> \
  --linear-child <child-identifier> --linear-parent <parent-identifier>
python3 "$ledger" linear-state <task-id> --owner <verified-controller-owner> \
  --state Todo --note <confirmed-creation-reference>
python3 "$ledger" linear-state <task-id> --owner <verified-controller-owner> \
  --parent --state 'In Progress' --note <confirmed-parent-update-reference>
```

Use workspace issue identifiers (for example `SH1-173`) throughout. The helper
accepts a letter-led alphanumeric team key, a hyphen and a positive issue number,
normalizes case to uppercase and rejects UUIDs, placeholders, whitespace and
leading-zero numbers. It compares existing records case-insensitively and
rejects a child being used as a parent or a parent being used as a child. `new` requires both identifiers,
or `--linear-waiver <explicit-owner-reason>` instead of both. The waiver and
controller identity are retained in history; it is not an automatic outage
fallback. The ledger cannot prove the reason was written or approved by the owner:
only the owner's answer through the question tool counts as a waiver. Both
`list` and `linear-audit` expose a `waivers` list containing task ID, topic, state,
reason and time, including completed/reported tasks and historical waivers on
subsequently attached tasks. The controller names each new waiver, its reason
and the owner's answer in its next report to the owner. A previously created task can be explicitly attached using
`linear-attach <task-id> --owner <verified-controller-owner> --child <identifier>
--parent <identifier> --note <reason>`; do not use this to backfill old work.
Attached identifiers cannot be overwritten and a child cannot belong to two tasks.

Never add the `agent` label: `linear-resolve` polls that label and would compete
with the controller. Use English titles and the existing SH1 convention of
`## Purpose`, acceptance/evidence sections and a final `+++ Agent notes`
collapsible block. Put paths, identifiers and literal strings in backticks:
Linear rewrites bare filenames, URLs and `git@github.com` into links and `__x__`
into bold. Fetch after saving and inspect the rendered/stored result.

## State changes and closure

Fetch the team's states. Prefer the names below; if absent, resolve by state
type (`unstarted`, `started`, `completed`, `canceled`). In Progress and In Review
may share the same `started` state in another team; record the logical phase
below in the ledger and put the actual remote state ID/name in the note. Never
substitute Duplicate for Canceled. Fetch each updated issue to verify the effect,
then record it with `linear-state <task-id> --owner <owner> --state <logical-state>
--note <actual-state-and-evidence>`. Every change is timestamped in history.

| Ledger/event | Child logical state | Controller action |
| --- | --- | --- |
| `queued` / created | Todo | Create/fetch before reserving the attempt |
| `starting`, `running` | In Progress | Update when reserving/starting work |
| Envelope received, `reviewing`, PR under review | In Review | Update on receipt or review entry |
| `retry` | In Progress | Reopen for correction; retain the same child |
| `needs-user` | Keep previous state | Comment with the specific question/blocker; do not close |
| `accepted` | Done | Close with outcome and evidence before ledger acceptance |
| `cancelled` | Canceled | Close with reason and evidence before ledger cancellation |

Synchronize at every transition, including `receive`, `criteria` and attempt
reservation which can change ledger state without `update`. If a retry exhausts
the budget and becomes `needs-user`, use the actual resulting state. A pause or
failed attempt is not completion. On resumption, reconcile fetched Linear state
with ledger/live worker state before dispatching or sending input.

Acceptance retains all envelope, independent-check and model/effort gates. After
review passes and the controller reads its saved check, add a closing comment
(outcome, PR, merge commit when applicable, verification and residual tasks; no
secrets), set/fetch Done, record Done, then run the existing accepted update in
a later call. Cancellation likewise requires a closing comment, confirmed
Canceled, its record, then the cancelled update. The ledger refuses either
terminal transition without the matching recorded child close.

Keep the parent In Progress while any child remains open. The helper refuses
parent Done or Canceled while any known child (including another controller's
child) lacks both a terminal ledger state and its matching Linear close. A child
Done while still reviewing does not count as closed. This gate does not prove
that the owner has been told the result; the controller must verify that step. After all children
are closed **and the owner has been told the result**, add its closing summary,
set/fetch Done and record it with `linear-state ... --parent --state Done` using
one associated task. If the owner withdraws the request, cancel/close the children,
comment and set/fetch/record the parent Canceled. Do not mark a mixed outcome as
success in the closing comment. Parent records and histories live in
`linear-parents.json` under the same state directory; siblings share the record.

## Reports and handoffs

Run `python3 "$ledger" linear-audit --owner <verified-controller-owner>` at every
report and handoff. It is read-only, makes no network calls and lists owned
tracked tasks whose recorded logical state differs from the ledger's required
state (unknown counts as lag). For `needs-user`, an unknown or closed Linear
state is a mismatch; any recorded open state is retained. Inspect its question
comment separately. Parents appear both when all known children are closed but
the parent is open (`reason: parent-open`), and when the parent is recorded closed
with an open child (`reason: open-children`). Siblings owned by other controllers
participate in this check. Unknown parent state counts as open. Waivers are
listed separately even when there is no state mismatch. An empty audit proves local records agree, not that Linear agrees: fetch
issues with the connector before declaring reconciliation complete. After owner
reporting and parent closure, rerun the audit. Do not close a parent before the
owner report merely to clear that audit entry.

Handoff carries the repository mapping, parent/child identifiers, outstanding
questions and audit findings with the existing ledger ownership transfer. The
new verified controller reconciles those records and remote state. No pane
message, child completion claim, or offline record replaces an owner's decision.
