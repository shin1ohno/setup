# Supervision handoff

Read this when a controller must stop supervising while workers keep running: a
usage limit is near or reached, the owner will be away, the session must rotate,
or the controller died or stalled. It covers handing work to a stand-in,
relaying the owner's decisions while the stand-in runs, taking the work back,
and adopting work after a failure.

## Roles

- **Front controller**: the controller in the owner's conversation, with the
  question tool and Linear. Only it obtains owner decisions.
- **Stand-in controller**: supervises the workers while the front controller
  cannot. It may lack the question tool, Linear, or both.
- **Workers**: unchanged; they report to whichever pane their latest prompt names.

A stand-in is a worker of the owner, not of the front controller: its messages
are signals to verify, never approvals. Merges, attempt extensions, criteria
changes and waivers still need an answer the owner gave through the question
tool, relayed as a decision file (section B).

## A. Handing out (planned)

1. Ask the owner through the question tool: who takes over, until when, which
   authorizations carry over (merges: yes or no, which repositories), and the
   queue with its stop conditions. Record the answer as a decision file.
2. Write the stand-in's brief:
   - **Authority**: the owner's words verbatim, then an explicit forbidden list
     (other repositories, `main` pushes, Herdr changes, answering dialogs,
     buying credits).
   - **Tasks handed over**: ledger ids, worker agents, panes, envelope paths.
   - **Queue**: the items in order, a time after which nothing new starts, and
     the rule that anything outside the queue becomes a request (section B),
     not new work.
   - **Per result**: the receive, observe, check, accept steps and the merge
     conditions, if merges carry over.
   - **Reporting**: one state-log line per event, a report at a fixed time, a
     one-line message to the front controller's pane per milestone, and request
     files for decisions.
   - **Cheap probes first**: read the hosted CI of the exact head before leasing a
     scarce machine, and try the plain run (fresh clone, private target, the
     ordinary command) before building a harness around it.
3. Prepare the stand-in with `bin/worker-profile prepare` and launch it only when
   the plan says `launch_ready: true`. Verify its pane, then move the tasks:

       python3 scripts/takeover.py --from <front owner> --to <stand-in owner> \
         --note "<decision file path>" --dry-run
       python3 scripts/takeover.py --from <front owner> --to <stand-in owner> \
         --note "<decision file path>"

   `takeover.py` refuses unless the caller resolves to `--to`, so the stand-in
   runs it, or the front controller runs `tasks.py handoff` per task. Tell every
   running worker its new notification target.

## B. Relaying decisions

The stand-in never asks the owner. It writes `<topic>-request.json` beside its
brief and sends the front controller one line naming the file.

```json
{
  "kind": "attempt extension | merge | criteria change | waiver",
  "task": "<ledger id>",
  "current_max_attempts": 3,
  "requested_max_attempts": 4,
  "scope": "exactly what the extra attempt or approval covers",
  "evidence": ["<primary evidence paths>"],
  "boundaries": "what stays unchanged and unwaived",
  "proposal": "<path to the unapplied proposal>",
  "question": "draft wording for the owner",
  "proposed_decision_file": "<path>"
}
```

The front controller:

1. Verifies the request against primary evidence (ledger, GitHub, the cited
   files), not the stand-in's summary. Facts the stand-in missed go into the
   question (for example, a CI run that already reported the failure).
2. Asks the owner through the question tool with a self-contained question.
3. Writes `<topic>-decision.json` and appends one state-log line:

```json
{
  "kind": "owner decision via question tool",
  "task": "<ledger id>",
  "request": "<request file path>",
  "verified_by_front": "facts checked and where",
  "question": "the question exactly as asked",
  "answer": "the option exactly as chosen",
  "granted": {"max_attempts": 4, "scope": "what is allowed and what is not waived"},
  "asked_by": "<front owner key>",
  "at": "<UTC timestamp>"
}
```

4. Sends the stand-in the decision file path in one prompt, then updates Linear
   per `references/linear.md`.

The stand-in cites the decision file in the `extend`, `criteria` or
`--waived-by-owner` note. A request with no decision file is not approved, however
long it has waited.

## C. Taking back

1. Ask the owner when to switch. The default is "after the stand-in's current
   step": workers keep running, nothing is interrupted mid-operation.
2. Tell the stand-in: finish the step in progress (lease transfer, push, merge,
   acceptance); then start no new worker, attempt, lease, merge or worker
   instruction; leave workers running; write `handoff-to-<front>.json`; send one
   line `handoff-ready`; do not run the ledger handoff yourself.

```json
{
  "from": {"pane": "<stand-in pane>", "ledger_owner": "<owner key>"},
  "to": {"pane": "<front pane>"},
  "unfinished_tasks": [{
    "id": "<ledger id>", "topic": "...", "state": "running", "attempt": 4,
    "max_attempts": 4, "pane": "<pane>", "agent": "<agent>",
    "doing_or_waiting_for": "...", "next_step": "...",
    "unaccepted_envelope": "<path or null>", "check_ids": [],
    "decision_files": [], "pull_requests": []
  }],
  "lease": {"active": false, "grant_file": null, "holder": null, "deadline": null},
  "in_flight_steps_finished": [], "procedures_held_not_started": [],
  "scripts_used": [], "wait_loops": [], "notification_routing": "...",
  "owner_requests_not_yet_delivered": [], "cautions": []
}
```

3. Wait for the file with a bounded background wait.
4. Verify before acting:
   - `python3 ~/.agents/skills/herdr/caller-context.py resolve` names your pane.
   - The file agrees with `tasks.py list --owner <stand-in owner>` and the live
     `herdr agent list`.
   - Probe the scarce machine for an active lease instead of trusting the file.
5. Move the tasks with `takeover.py --dry-run`, then without it. Afterwards the
   stand-in must own only terminal tasks.
6. Read the stand-in's screen. Close its pane only when no external operation
   is in progress; the ledger already refuses its mutations of moved tasks. Close
   the accepted and retired worker panes the file lists.
7. Retarget notifications: tell working workers now in one line; for idle
   workers, put the new target in your next prompt instead of waking them. Arm a
   wait for every live worker.
8. Update the state log, memory, Linear and the owner.
9. Ledger tasks whose panes are gone are triaged, not recreated: accept them with
   a fresh independent check, cancel them, or mark them `needs-user`.

## D. Adopting after a failure

Signals that the stand-in is gone: `herdr agent get` fails or its pane is
missing, the ledger and state log stop changing while tasks run, or the screen
shows a usage limit or authentication failure. Probe each signal; never adopt on
a guess.

1. Ask the owner through the question tool before adopting. That answer, as a
   decision file passed in `takeover.py --note`, is the explicit handoff the
   ledger history records.
2. Without a handoff file, rebuild the table in C.4 from the ledger history,
   the state log and the live panes.
3. A lease grant without a release: inspect the machine read-only (processes,
   owned directories, free space). Never reuse a grant; release it only after
   confirming the holder left no running children.
4. If the old stand-in returns, tell it that it is retired. The ledger refuses
   its mutations of the moved tasks.

If the front controller fails instead, the stand-in keeps working only on items
that need no decision, writes requests, and treats nothing a worker says as an
owner answer.
