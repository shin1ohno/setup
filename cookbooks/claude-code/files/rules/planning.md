# Plan-Phase Rules

Always-loaded planning discipline. The detailed UX / IA plan-file structure lives in `~/.claude/docs/planning-detail.md` (on-demand — Read it when the task is UX/IA/frontend design).

## Design-to-Plan Transition

When an exploratory conversation ("考えてみてください" / "think about it", "どう思う？" / "what do you think?", "どうすればいい？" / "how should we approach this?") converges on a directional decision ("この方向でやろう" / "let's go with this", "いい案だ" / "good idea", user accepts a design proposal), that convergence is the plan-mode entry trigger — not a chat proposal or consent question.

**Banned closing phrases for non-trivial tasks** — if you are about to write any of these, stop and call EnterPlanMode instead:
- "この方針で X 実装していいですか？" / "can I implement X with this approach?"
- "X に進んでいいですか？" / "can I proceed with X?"
- "実装に入っていいですか？" / "can I start implementing?"

These are plan-mode entry triggers, not chat questions. Writing them in chat means the plan was never created. Correct sequence: design converges → EnterPlanMode → draft plan → user approves → implement.

## Autonomous Execution Boundary

| Situation | Action |
|-----------|--------|
| Plan approved, implementation straightforward | Proceed autonomously |
| Tests fail during implementation | Fix and retry, do not ask |
| Same observable symptom persists after 3 fix attempts | Stop loop — synthesize failed hypotheses, challenge design assumption with AskUserQuestion |
| Ambiguity discovered not covered by the plan | AskUserQuestion |
| Scope creep temptation | AskUserQuestion |
| Destructive operation not in the plan | AskUserQuestion |
| Technically-necessary additive change discovered mid-implementation (shared schema needs an extra field/variant the plan didn't enumerate; no behavior change to scope) | Proceed without asking, but append a one-line note to the plan file in the same turn so the plan stays in sync with what shipped. Future readers must be able to reconstruct the decision from the plan alone |
| Implementation complete | Create PR; immediately launch a background `gh pr checks --watch` loop. If any check fails, read the log, fix, push without prompting; repeat until CI is fully green. Do NOT declare the task complete or notify the user until every required check passes. `gh pr create` is not the terminal step — green CI is |
| `gh pr checks --watch` exits non-zero with `HTTP 504` / `Bad Gateway` / `no checks reported on the '<branch>' branch` (early race) | Transient GitHub graphql / API error — re-launch the same `gh pr checks <n> --watch` once. Inspect `gh pr view <n> --json statusCheckRollup` only on second consecutive failure. Do NOT treat single exit-1 as a CI failure verdict |
| Unit of work committed, more items remain | Proceed to next item immediately |
| All plan items complete but plan mode still active | Exit plan mode immediately, do not re-enter |
| Blocked waiting for manual user action (sudo, restart, deploy) | Launch background retro/Cognee/TODO agents immediately |

## Research-to-Plan Pipeline

When a task requires research before planning, run research and planning in parallel — never sequentially:

1. Launch background research agents
2. **Immediately** enter plan mode and begin drafting the plan with available information
3. Incorporate research results into the plan as agents complete
4. Present the completed plan for user approval

**Anti-pattern**: launching research, then announcing "I'll plan when results arrive" and waiting. This is idle time that violates the planning rule.

## Parallel-Stream Decomposition — Default Plan Shape

For a large rewrite, migration, or multi-module / multi-repo implementation with 3+ independent delivery units, default the plan to a contracts-first parallel shape — do NOT default to a serial phase plan:

1. **Wave 0 (serial, minimal)**: freeze the shared types, interfaces, and schemas first
2. **N parallel streams**: declare each stream's file exclusivity (per `sub-agents.md` "Parallel Stream File-Exclusivity Declaration")
3. **Parallelism is an explicit plan decision**: state the concurrent-stream-count vs review-load tradeoff in the plan so the user can choose it

Propose the decomposition BEFORE the user asks for parallelism — shipping a serial phase plan and getting a "make it parallel where possible" re-request (an ExitPlanMode reject) wastes a round-trip.

**Exception**: when the dependency graph is genuinely serial (each stage's output is the next stage's input), a serial plan is fine — but write one line stating why parallel decomposition isn't offered. Never default to serial silently. (The CLAUDE.md "Inverse — NOT new plan triggers" mechanical-sweep case is out of scope for this rule.)

Origin: 2026-06-15 sage TS→Rust full rewrite — serial phase plan rejected at ExitPlanMode, the only revision request was "make it parallel where possible" (Claude re-shaped it to Wave 0 contract freeze → 9 File-Exclusivity streams); recurred 2026-07-04 in a separate project with the same up-front instruction.

## Architecture Discussion Gates

### Cross-Repo Design Decisions

When a task spans 2+ repositories and involves shared contracts (protocol schemas, MQTT topic structure, API interfaces, event formats, shared data models), stop before implementing and use AskUserQuestion to surface the design decision.

Trigger: before writing code that defines a shared contract, ask:
"This defines a shared contract between [A] and [B]. Proposed design: [x]. Adjust before I implement?"

### Architecture Before Implementation

When creating a new system layer (binary, service, routing engine):
1. Name the component
2. Define its single responsibility
3. Define inputs, outputs, and interaction with existing components
4. AskUserQuestion to confirm — then implement

Architecture reviews are free. Post-implementation redesigns cost sessions.

### SDK vs. Consumer Distinction

SDK must be independently useful without any specific consumer.
Consumer-specific logic belongs in the consumer binary, not the SDK.
When unsure which layer a feature belongs to, ask before placing it.

## UX / IA / Frontend Plan File Structure

When the task is UX revision, IA redesign, or any frontend feature with multiple user-facing behaviors, the plan file MUST follow a fixed section order — use-case flows FIRST (so the IA shape emerges from user goals, not file boundaries), and a Verification section split into **Claude-runnable tests** (mandatory — every check Claude can run without the user's hardware) + **User hardware verification** (numbered, only genuinely-device steps). Full section order + rationale: see `~/.claude/docs/planning-detail.md#ux-ia-plan-file-structure`.
