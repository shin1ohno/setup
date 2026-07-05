# Plan-Phase Rules — Examples & Origin Notes

On-demand detail for `~/.claude/rules/planning.md`. Read when the task is UX / IA / frontend design.

## ux-ia-plan-file-structure

When the task is UX revision, IA redesign, or any frontend feature with multiple user-facing behaviors, the plan file MUST follow this section order:

1. **Context** — problem statement + user-confirmed constraints (1 paragraph)
2. **ユースケース別 操作フロー (use-case flows)** — for each primary use case, show the actor + goal + concrete step-by-step interaction. Side-by-side "いま / 新しく" table when revising existing behavior. This section comes FIRST because it forces the IA shape to emerge from user goals, not from file boundaries
3. **Scope / Out-of-scope** — explicit boundaries
4. **構造変更 (structural changes)** — code-level changes grouped by module, derived from the use cases above
5. **ファイル一覧 + 既存ユーティリティの再利用**
6. **Verification** — split into two subsections:
   - **Claude-runnable tests** — every check Claude can execute without the user's hardware: type checks, unit tests, integration tests against real services running locally (sqlite, docker, weave-server), API curl probes that surface the bug class, end-to-end test scripts that spin up containers / mock devices. List the exact command for each, AND the bug class it would have caught. **This subsection is mandatory** — if a bug shipped to user-hardware verification could have been caught by a script Claude could run, that script belongs here.
   - **User hardware verification** — only the steps that genuinely require a physical device (BLE press, Roon zone playback state, Hue light reaction). Number them so the user can report "step 3 failed" rather than describing the failure ad-hoc.

Why the split: many bug classes (missing enum variant, dispatch routing, tile-input regressions) are observable without user round-trips. Why this order: user-journey-first makes implementation priority obvious (primary UC → secondary UC) and prevents the rewrite triggered by "最初にユースケースごとの操作を書いて". Origin: 11-bug cascade, each fix lacked an autonomous test pass.
