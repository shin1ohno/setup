# Plan-Phase Rules — Examples & Origin Notes

Load when a `~/.claude/rules/planning.md` pointer matches the current task (UX / IA / frontend plan structure, CI-watch failures, partition fidelity, parallel decomposition, added-layer justification).

## autonomous-execution-boundary

**`gh pr checks --watch` 504 / "no checks reported"**: these are transient GitHub graphql / API errors in the early race, so re-launch the same `gh pr checks <n> --watch` once. `mergeStateStatus` of `DIRTY` / `CONFLICTING` means GitHub will never run checks on the PR — stop polling, rebase onto the base branch, force-push, re-watch. A mid-flight sibling merge touching the same files is the common cause. Origin: 2026-07 setup #696 — "no checks reported" ×2 was a conflict from #695 merging mid-flight, not a race.

**Long foreground run**: the "hasn't heard from you in a while" reminder is a hard trigger — the reply after it must carry progress, not a silent resumption. Origin: 2026-09-22 home-monitor — the reminder fired 4+ times in one session across ARP/ES probing, four PR cycles and a provider fix-and-release.

## requested-partition-fidelity

A partition is never silently merged away or dropped; merging or omitting one is decided before starting, not after delivering. Putting the partition list into workflow `schema` keys makes a missing partition fail structurally instead of arriving as a plausible-looking imbalance. The shared AGENTS.md 増分更新の棚卸し diffs line counts against the prior version and marks unverified rows; this rule is the same discipline for the FIRST version.

Origin: 2026-07-24 — a knowledge-worker overtime study whose request spelled out five outcome classes ((1) physical health (2) mental health: depression / anxiety / burnout (3) cognition (4) productivity (5) employment sustainability) came back weighted toward vascular disease. The user rejected it (「いずれも肉体労働を中心とした、物理的な血管などの疾患に寄りすぎていませんか？…その前提で調査と分析をやり直して欲しいです」) and one whole deep-research workflow run was wasted.

## parallel-stream-decomposition

Shape:

1. **Wave 0 (serial, minimal)**: freeze the shared types, interfaces, and schemas first
2. **N parallel streams**: declare each stream's file exclusivity (per `sub-agents.md` "Parallel Stream File-Exclusivity Declaration")
3. **Parallelism is an explicit plan decision**: state the concurrent-stream-count vs review-load tradeoff in the plan so the user can choose it

Propose the decomposition BEFORE the user asks for parallelism — shipping a serial phase plan and getting a "make it parallel where possible" re-request (an ExitPlanMode reject) wastes a round-trip. A genuinely serial graph is one where each stage's output is the next stage's input; never default to serial silently.

**Downstream count from upstream discovery**: when a later phase fans out over whatever an earlier phase enumerates (verify each finding, migrate each call site, deep-read each source), the count is unknown at plan time and a guessed cap silently truncates coverage. Run discovery on its own first, then derive the fan-out — `ceil(N / batch_size)`, or one stream per category when items group naturally. Two invocations you stay between beat one invocation with a guessed cap: you read the real count, and any cap you impose is a stated decision. Origin: 2026-08-05 — a workflow fixed its verify fan-out at 8 while discovery returned 99 entries; the run was stopped mid-flight and re-shaped into category-based streams, wasting the first run's verify budget.

**Parallel document drafting**: Wave 0 fixes every definition two or more sections reference — identifiers, field and property names, JSON shapes, key formats, error codes, caller lists — before any drafter starts. Decisions record *which* option was picked; contracts record *what the shared names and shapes are*, and parallel drafters diverge on the second even when they agree on the first. Origin: 2026-09-26 — six parallel section drafters bound only by a decisions file defined the canonical record three different ways; closing the drift took a separate contracts-reconcile pass plus fix/verify loops that ran for about 6h40m.

Origin: 2026-06-15 sage TS→Rust full rewrite — serial phase plan rejected at ExitPlanMode, the only revision request was "make it parallel where possible" (re-shaped to Wave 0 contract freeze → 9 File-Exclusivity streams); recurred 2026-07-04 in a separate project with the same up-front instruction.

## standard-mechanism-first

Reasons an extra layer can buy: smaller exposed surface, an audit requirement, an existing fleet convention. The Existing-facility probe in `~/.agents/AGENTS.md` asks "does a facility exist here?"; this gate asks "does the platform already do this without any facility?".

Origin: 2026-07-30 sh1-cloud — the user pushed the solution shape back three times in one session (「普通にssh authorize keyを登録しておけばいいだけじゃないんですか？なぜここでtailscaleを使うのでしょう？」「ちょっとソリューションがズレている気がします。tailscaleで同じネットワークで入り、tailscaleに依存しない普通のsshでログインしたいです」「ちょっと待って。githubにsshできるように鍵を設定する方が良いのでは？」), each time against a layer proposed ahead of the plain mechanism. The end state kept Tailscale as the network but moved auth back to plain ssh keys.

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
