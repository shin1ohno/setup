# Plan-Phase Rules

Examples, origins and the UX / IA plan structure: `~/.claude/docs/planning-detail.md` (on-demand).

## Design-to-Plan Transition

An exploratory conversation ("考えてみてください", "どう思う？") converging on a direction ("この方向でやろう", "いい案だ", proposal accepted) is the plan-mode entry trigger, not a chat consent question. **Banned closings for non-trivial tasks** — 「この方針で X 実装していいですか？」「X に進んでいいですか？」「実装に入っていいですか？」 (or English equivalents): call EnterPlanMode instead.

## Autonomous Execution Boundary

| Situation | Action |
|-----------|--------|
| Plan approved, implementation straightforward | Proceed autonomously |
| Tests fail during implementation | Fix and retry, do not ask |
| Same observable symptom persists after 3 fix attempts | Stop loop — synthesize failed hypotheses, challenge design assumption with AskUserQuestion |
| Ambiguity discovered not covered by the plan | AskUserQuestion |
| Scope creep temptation | AskUserQuestion |
| Destructive operation not in the plan | AskUserQuestion |
| Technically-necessary additive change mid-implementation (extra schema field/variant, no scope change) | Proceed without asking; append a one-line note to the plan file in the same turn so the plan alone reconstructs the decision |
| Implementation complete | Create PR, launch a background `gh pr checks --watch` loop at once; on failure read the log, fix, push unprompted, repeat. Not complete (no user notice) until every required check is green |
| `gh pr checks --watch` exits non-zero with `HTTP 504` / `Bad Gateway` / `no checks reported on the '<branch>' branch` | Re-launch once; on a second failure read `gh pr view <n> --json statusCheckRollup,mergeStateStatus`: `DIRTY` / `CONFLICTING` → rebase, force-push, re-watch; only an empty rollup with `CLEAN` / `UNSTABLE` / `BEHIND` is transient. A single exit-1 is not a CI-failure verdict. Detail: see `~/.claude/docs/planning-detail.md#autonomous-execution-boundary` |
| Unit of work committed, more items remain | Proceed to next item immediately |
| ~8-10 consecutive foreground tool calls with no user-facing text, or a harness "hasn't heard from you in a while" reminder | Emit one line (current step + next) before the next tool call; after the reminder the reply must carry progress. Foreground counterpart of CLAUDE.md's background-poll rule |
| All plan items complete but plan mode still active | Exit plan mode immediately, do not re-enter |
| Blocked waiting for manual user action (sudo, restart, deploy) | Launch background retro/memory/TODO agents immediately |

## Research-to-Plan Pipeline

When research precedes planning, run both in parallel: launch background research, **immediately** draft in plan mode, fold results in as they land, then present. Waiting for results before planning is a violation.

## Requested-Partition Fidelity — mirror the asked-for breakdown into the deliverable

Partitions the request enumerates (outcomes, viewpoints, segments, axes, comparison targets) become the deliverable's section headings **1:1**; an evidence-less partition keeps its section and says 「証拠なし」/「データ未取得」. Merging or dropping one is a scope decision → AskUserQuestion before starting. For a workflow or sub-agent, put the partitions into the `schema` keys. This is AGENTS.md 増分更新の棚卸し applied to the first version.

Detail: see `~/.claude/docs/planning-detail.md#requested-partition-fidelity`.

## Parallel-Stream Decomposition — Default Plan Shape

For a rewrite / migration / multi-module or multi-repo job with 3+ independent units, default to contracts-first parallel, proposed unasked: Wave 0 freezes shared types/schemas; streams declare file exclusivity (`sub-agents.md`); state the stream-count vs review-load tradeoff. A genuinely serial graph stays serial with a one-line reason (mechanical sweeps out of scope). Derive a fan-out count from an upstream discovery run first, never a guessed cap. 3+ parallel drafters of one document need a Wave 0 *contracts* file (shared names/shapes), not just a decisions file.

Detail: see `~/.claude/docs/planning-detail.md#parallel-stream-decomposition`.

## Architecture Discussion Gates

### Standard Mechanism First — justify every added layer

Before a plan adds a NEW mechanism (tunnel, proxy, bespoke secret path, wrapper, sync daemon), write one line on whether the platform's **standard** mechanism suffices (plain ssh + `authorized_keys`, the CLI's default auth, a direct IAM grant, the service's scheduler). If it does and you still add the layer, state what it buys and put it through AskUserQuestion; a plan without that line is incomplete.

Detail: see `~/.claude/docs/planning-detail.md#standard-mechanism-first`.

### Cross-Repo Design Decisions

When a task spans 2+ repos with a shared contract (protocol schema, MQTT topics, API, event format, shared model), stop before writing it and ask via AskUserQuestion: "This defines a shared contract between [A] and [B]. Proposed design: [x]. Adjust before I implement?"

### Architecture Before Implementation

For a new system layer (binary, service, routing engine): name it, define its single responsibility, inputs/outputs and interactions, confirm via AskUserQuestion, then implement.

### SDK vs. Consumer Distinction

An SDK must be useful without any specific consumer; consumer-specific logic belongs in the consumer binary. When unsure of the layer, ask before placing it.

## UX / IA / Frontend Plan File Structure

For UX revision, IA redesign, or a frontend feature with multiple user-facing behaviors, the plan file MUST use the fixed section order: use-case flows FIRST, and Verification split into **Claude-runnable tests** (mandatory) + numbered **User hardware verification** (device-only steps). Detail: see `~/.claude/docs/planning-detail.md#ux-ia-plan-file-structure`.
