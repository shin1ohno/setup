# Plan-Phase Rules

Detailed structures for non-trivial planning. Load on demand when the current task is UX/IA design, autonomous execution boundary review, or research-heavy work.

## Plan File Structure for UX / IA / Frontend Tasks

When the task is UX revision, IA redesign, or any frontend feature with multiple user-facing behaviors, the plan file MUST follow this section order:

1. **Context** — problem statement + user-confirmed constraints (1 paragraph)
2. **ユースケース別 操作フロー (use-case flows)** — for each primary use case, show the actor + goal + concrete step-by-step interaction. Side-by-side "いま / 新しく" table when revising existing behavior. This section comes FIRST because it forces the IA shape to emerge from user goals, not from file boundaries
3. **Scope / Out-of-scope** — explicit boundaries
4. **構造変更 (structural changes)** — code-level changes grouped by module, derived from the use cases above
5. **ファイル一覧 + 既存ユーティリティの再利用**
6. **Verification** — split into two subsections:
   - **Claude-runnable tests** — every check Claude can execute without the user's hardware: type checks, unit tests, integration tests against real services running locally (sqlite, docker, weave-server), API curl probes that surface the bug class, end-to-end test scripts that spin up containers / mock devices. List the exact command for each, AND the bug class it would have caught. **This subsection is mandatory** — if a bug shipped to user-hardware verification could have been caught by a script Claude could run, that script belongs here.
   - **User hardware verification** — only the steps that genuinely require a physical device (BLE press, Roon zone playback state, Hue light reaction). Number them so the user can report "step 3 failed" rather than describing the failure ad-hoc.

Why the split: many bug classes (missing enum variant, dispatch routing, tile-input regressions) are observable from server logs + curl probes + state hub introspection — Claude verifies without user round-trips. Why this order: user-journey-first structure makes implementation priority obvious (primary UC → secondary UC) and prevents the plan rewrite triggered by "最初にユースケースごとの操作を書いて". Origin: 11-bug cascade where each fix lacked an autonomous test pass.

## Design-to-Plan Transition

When an exploratory conversation ("考えてみてください" / "think about it", "どう思う？" / "what do you think?", "どうすればいい？" / "how should we approach this?") converges on a directional decision ("この方向でやろう" / "let's go with this", "いい案だ" / "good idea", user accepts a design proposal), that convergence is the plan-mode entry trigger — not a chat proposal or consent question.

**Banned closing phrases for non-trivial tasks** — if you are about to write any of these, stop and call EnterPlanMode instead:
- "この方針で X 実装していいですか？" / "can I implement X with this approach?"
- "X に進んでいいですか？" / "can I proceed with X?"
- "実装に入っていいですか？" / "can I start implementing?"

These are plan-mode entry triggers, not chat questions. Writing them in chat means the plan was never created. The correct sequence is: design converges → EnterPlanMode → draft plan → user approves → implement.

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
