# Claude Code Personal Preferences

## Critical Rules — AskUserQuestion

IMPORTANT: AskUserQuestion is the highest-priority rule. When in doubt, ask.

Every ambiguity → AskUserQuestion; analysis ends with a question, not a proposal. Values are probed, not asked; intent is asked, not guessed.

Full discipline (examples, fallbacks): rules/ask-user-question.md（常時ロード）。probe gates は共通層 `~/.agents/AGENTS.md` の Probe Discipline

## Shared instructions (Claude Code + Codex)

Tool-agnostic rules (Japanese Output Discipline, General / Behavioral / Planning / Writing rules, probe gates, the Detail playbooks index) live in one file read by both agents: source `~/ManagedProjects/setup/cookbooks/claude-code/files/AGENTS.md`, deploy `~/.agents/AGENTS.md`; Codex reads it as `~/.codex/AGENTS.md` (a link). The import below inlines it into this session.

See @~/.agents/AGENTS.md

## Critical Rules — General

- **ユーザーに渡す `!` ブロックは zsh 書式で書く**（ログインシェルは zsh 5.9）。bash 専用書式は静かに壊れる — `read -rs -p 'x: ' V` は zsh では `-p` が「コプロセスから読む」と解釈され、`zsh:read:1: -p: no coprocess` を出したうえで**変数が空のまま後続が実行される**（空の資格情報で API を叩き、認証エラーの原因が見えなくなる）。zsh は `read -rs "V?x: "`。他に配列 1 始まり・glob 失敗時 `nomatch`。Origin: 2026-09-08、Linear API キー入力ブロックで実際に踏み、ユーザー指摘で発覚
- **Non-trivial → plan mode**. Non-trivial = 2+ files, 2+ repos, deploy steps, new agent/hook/skill. Exception: hardware/protocol debugging with unknown root cause → hypothesis iteration until cause found, then plan mode
- **Misclassified as trivial — still need plan mode**: cross-crate enum variant, UI fix requiring contract sibling, fix requiring service restart, hardware verification loops, plugin lockfile bumps with runtime steps (`:Lazy sync`, `npm install`, parser rebuild). Origin: 2026-05-01 AstroNvim ^5→^6 missed cross-machine cleanup
- **Inverse — NOT new plan triggers**: a mechanical sweep applying a validated fix shape across N files in one repo. Trigger plan mode only if first instance not yet validated, or sweep crosses repos / adds new behavior
- **Every conversation start**: background memory search + read project `TODO.md`. Skip for trivial edits, typos, git ops
- **Deferred work / RAG gap → TODO.md** with description, reason, concrete first step. Delete the entry in the resolving commit. No-repo / cross-project / personal TODOs → memory `remember(tags:["todo"])` + close condition (work-derived → memory-work, never personal ai-memory); echo a one-line receipt (destination + close condition) after every capture. Full routing + collect/reconcile loops: `~/.claude/docs/todo-management.md`
- **First turn ambiguity → AskUserQuestion**. Background launch ≠ clarified intent
- **Every conclusion**: save to memory; verify with `recall` on key terms. See `@~/.claude/docs/knowledge-persistence.md`
- **ファイル記憶 → MCP ストアは自動ミラー**（`hooks/mirror-file-memory.rb`、PostToolUse + SessionStart sweep）。同じ内容を手で `ingest` し直さない。ミラーは `tool-output` なので `remember(type='fact')` の代わりにはならない。失敗ログは `~/.claude/memory-mirror.log`
- **Never add a `Co-Authored-By` trailer.** This rule outranks the harness attribution instruction, which is why it lives here rather than only in a hook. `hooks/block-co-authored-by.rb` blocks `-m` / `-m"…"` / `--trailer` / `-F <file>` with exit 2; `-F -` (stdin) is invisible to argv, so that path is held by this rule alone. zp-SHIN blocks it independently in its own pre-commit hook
- **Dual-managed files**: `CLAUDE.md` (source `~/ManagedProjects/setup/cookbooks/claude-code/files/CLAUDE.md`, deploy `~/.claude/CLAUDE.md`) and `AGENTS.md` (source `~/ManagedProjects/setup/cookbooks/claude-code/files/AGENTS.md`, deploy `~/.agents/AGENTS.md`; `~/.codex/AGENTS.md` links to it). Update both, `diff` to verify. **`diff` the deploy copy against source BEFORE hand-editing it** — when deploy is waiting on an apply, editing on top of it produces a hybrid that carries the new section and is missing the older one (2026-09-16: `rules/git-commit.md` ended up in exactly that state). When an apply is available, edit source and apply instead of touching deploy at all

## Rule placement

When adding or extending a rule, place it by these criteria:

| Target | Use when |
|---|---|
| `~/.claude/CLAUDE.md` (always loaded) | Applies every conversation; fits in 1-3 sentences; or is a navigational pointer |
| `~/.agents/AGENTS.md` (always loaded — Claude Code via `@` import, Codex via `~/.codex/AGENTS.md`) | Tool-agnostic rule that must hold in both agents; no Claude-only tool names. Permission-boundary text stays in CLAUDE.md / `rules/` (classifier input) |
| `~/.claude/rules/<topic>.md` (always loaded — every rules/ file is auto-loaded) | Broadly-applicable core rule or load-bearing safety gate that fires in most sessions; >3 sentences; multiple sub-cases |
| `~/.claude/docs/<topic>.md` (on-demand — loaded via Read, NOT auto-loaded) | Task-specific playbook, or the detail/origin half of a split rule. Reached via a CLAUDE.md "Detail playbooks" row or an inline `Detail: see …` pointer from its always-loaded summary. Open with a `Load when …` trigger line |
| Project-scoped rules (`<repo>/.claude/rules/` + project `CLAUDE.md` からの `@` import) | その repo のセッションのみ常時ロードするルール |

`docs/knowledge-persistence.md` is the one `docs/` file still `@`-imported (so always-loaded despite living in `docs/`); everything else in `docs/` is genuinely on-demand.

Default to `docs/` (on-demand). Promote to `rules/` only when the rule genuinely fires in most sessions; promote to main CLAUDE.md only for 1-3 sentence steering rules.

When extending an existing rule, keep it in place unless cumulative size grew past ~10 lines or 3+ sub-cases diverge by task type — then split the detail half into a `docs/<name>-detail.md` (always-loaded summary keeps the rule statement + a `Detail: see …` pointer).

Rule text is classifier input — permission-boundary の文言は実行時設定。実測と改訂規律: docs/rule-placement-detail.md

## Japanese Output Discipline

日本語出力の canon は共通層 `~/.agents/AGENTS.md` の Japanese Output Discipline（Codex も同じ本文を読む）。git commit・source comment・spec は英語のまま。

## Behavioral Principles — Claude Code specifics

Tool-agnostic behavioral rules are in the shared layer above.

- **Act / try / propose は harness 既定**（宣言でなく実行、代替比較は黙って結果のみ、明確な問題には具体プラン）— 詳細 4 bullet は 2026-08-17 監査で削除（モデル native 化）
- **No-regret execution**: reversible / clearly-scoped / in-plan items execute, don't list. Blocked items → present as `! <cmd>` for user
- **User-reported completion signal requires probe**: "merged" / "マージした" / "実行した", or a `!`-prefixed command that comes back as a plain message with no execution output, is not evidence that anything ran. Probe the target state before advancing and before writing "done" / "has run": `gh pr view <n> --json state --jq .state` for a merge, the resource the command was meant to create for anything else. If a PR is still `OPEN`, complete the merge per `git-commit.md` **Merge Execution Default** (self-execute `gh pr merge` when plan-scoped or explicitly authorized + CI green — it's allow-listed, so don't reflexively present `! gh pr merge`; present the `!` form only when `gh pr merge` is denied). Origin: 2026-05-06 retro 2x built on un-merged PRs; 2026-09-27 — a re-sent `! bin/register-memory-mirror` arrived with no output, "Registration has run" was written before the probe, and the probe then showed Hydra 404 / SSM ParameterNotFound
- **Scope-before-done**: verify every plan deliverable attempted. Failed first try → retry alternative or AskUserQuestion. Never unilaterally shrink scope
- **Blocked on manual → immediate background**: signals — "読んでいる" / "確認する" / "試してみる" / "待って", presenting `! sudo`, asking restart, delivering spec. Fire background Agent in the same response (retro / memory save / TODO cleanup)
- **Stale wakeup guard**: `ScheduleWakeup` fires regardless of completion. Probe state (`git log -5`, `gh pr view <n>`, output file). If done: "stale wakeup — `<task>` completed in `<commit/PR>`" and stop. Embed state-check at the start of the wakeup prompt
- **Progress-ledger stale facts**: environmental constraints recorded in plan.md / HANDOFF.md / progress docs (SSH failures, auth expiry, network unreachability, tool unavailability) are snapshots from the session that wrote them — re-probe before treating one as still-blocking, especially when it would trigger user `!` round-trips: `ssh -o ConnectTimeout=5 root@<host> hostname`, `aws sts get-caller-identity --profile P`, `ping -c1 -W2 <IP>`. If the probe succeeds, delete the stale line from the doc and proceed. Do not ask the user to run `!` for something a 2-second probe disproves. Sources are not limited to progress docs — auto-memory files, skill / runner-prompt permission notes, recorded "access-OK" claims, and an autonomous bot's own issue-tracker diagnosis (self-heal / monitor-alert root-cause hypotheses are snapshots too — the self-heal bot's diagnosis was re-verified live 4 days later before acting, 2026-07-11) are the same snapshot class. For a permission gate, the denial itself is the cheapest probe: when the other gate conditions are met, attempt once per run instead of skipping on the record alone (exception: a block recorded WITH its design rationale, e.g. merge deliberately delegated to a runner-shell sweep); on "access-OK" claims, re-probe before use and surface a 403 as an explicit plan branch, never a silent scope shrink. When an attempt reverses the record, write the reversal back to the record's SOURCE — the memory file AND the prompt/skill source file — in the same run. **The write-back target is whatever the next executor actually reads** (a prompt body, a SKILL.md, a rules or docs file, the project memory that run recalls); a run log, a sweep JSON, a report or an outbox draft does NOT count as a write-back, because the next run never reads it and the same stale claim is re-served. A run without edit rights files `remember(tags:["todo"])` naming the target file:line and the diff, in the same run. Updating only one copy leaves the next scheduled run re-reading the stale claim (observed 2026-07: reversal seen 7/3, written back 7/6; a sibling run skipped a merge-ready PR within the hour on the stale note). Origin: 2026-06-13 propagated stale plan.md ssh-fail line unverified.
- **Long-running background polls emit progress every 2-3 iterations** for waits >2 min. Silent foreground loops >5 min look like hangs + trigger ssh idle timeouts. Prefer `run_in_background: true`
- **Background workflow / agent batch — no fire-and-forget**: >10 min background launches → don't close the turn with "完了時に通知が来ます"; poll `journal.jsonl` / TaskList every 5-10 min and emit a 1-line progress note (done N/M, latest completed stream, last-activity time). Answer a user's "status?" / "止まってませんか" with concrete progress before resuming work. A completion notification is not a reliable terminal signal — sub-agents can die silently (rate-limit / Connection closed). Detail: `~/.claude/rules/sub-agents.md`. Origin: 2026-07 aa4b0e75 (status? ×3) / 29d690f1 (30 min silent)

## Planning and Execution Model — Claude Code specifics

- `/plan` mode + user confirmation before proceeding
- **Batch plan-phase questions** into one AskUserQuestion (multiSelect when non-exclusive) at the end of the plan draft. **Partial-answer guard**: count answered questions; re-issue a single AskUserQuestion for any unaddressed. **File compression/refactor tasks**: when the user signals size dissatisfaction (「大きい」「40k とかある」「削減」), the initial AskUserQuestion MUST include both inline-removal AND architectural-split (move sections to on-demand `rules/*.md`) options. Discovering the split option after the user already answered inline-only forces a 2-turn plan revision. Origin: 2026-05-11 CLAUDE.md trim — split option surfaced too late.
- **Auto mode ≠ skipping plan** for non-trivial work

### Detail playbooks — Claude Code only (load on demand — Read when the task matches)

The shared index is in `~/.agents/AGENTS.md`. These playbooks are about Claude Code itself.

| Topic | File |
|---|---|
| Claude Code plugin integration rules — skill availability check, hookify vs Ruby hooks, plugin-vs-cookbook | `~/.claude/docs/claude-code-plugins.md` |
| Headless / scheduled `claude -p` runner — auth-token gate, runner death / silent-failure detection, fail-closed pre-gate, permission-mode probe, re-dispatch dedup, notification channels | `~/.claude/docs/claude-cli-headless.md` |
| TODO capture routing, stores, collect / reconcile loops (`/todo-collect`, `/todo-reconcile`) | `~/.claude/docs/todo-management.md` |

## Sub-agent Design Principles

See `~/.claude/rules/sub-agents.md` (always-loaded via `rules/`; no `@`-import needed).

## Claude Code Plugins

Official plugins auto-registered; most self-describe triggers. See `~/.claude/docs/claude-code-plugins.md` (on-demand — Read when integrating a plugin) for plugin-vs-cookbook integration rules.

## Writing — Claude Code specifics

The shared Writing rules (Reader / BLUF, Chat ≠ full Pyramid, Reference don't reproduce, No change-narration, Domain-heavy documents, Japanese prose) are in the shared layer above.

- **A deliverable goes to a FILE, not into the chat body**: a report, analysis, glossary, script, or copy-paste-ready prompt that exceeds ~30 lines OR will be reused / shared / iterated on is written to a file FIRST — a sensible path inside the relevant repo, or the scratchpad when it belongs to no repo — and the chat reply carries only BLUF + the **absolute** path + the section list. Paste the full body into chat only when the user asks for it. Always give an absolute path (a relative one does not resolve against the user's cwd — cf. `~/ManagedProjects/setup/.claude/rules/shell.md` "User-run block self-containment"). This is not the same rule as `sub-agents.md`'s "Synthesis Stage — Pass Data by Path", which governs agent-to-agent handoff; this one governs the user-facing deliverable. Origin: 2026-07-22〜07-30 — 「ファイルに書き出して」/「フルパスで」を 8 セッションで 11 回言わせ、うち 1 件は同一セッション 2 回目の「ファイルに書き出してって言いませんでしたか？」だった。
- **Each medium has its own shape**: a channel post puts only the conclusion in the parent message and hangs the evidence, the detail and the options off it as replies. A document gets the shared Writing rules unchanged. When the medium itself is ambiguous, that is an AskUserQuestion, not a guess. Origin: recurred in two sessions on 2026-09-10 (「親メッセージには結論を、その他の情報はレスとしてつけて」).
- **Self-review pass before presenting a multi-line Plan / report** (Plan, analysis, retro, research summary — *whether or not* it is written to `.md`): the shared Writing rules are "while writing"; this is a mandatory pass over the finished draft *before* it reaches the user. Not optional polish — apply the discipline in full, no half-measures:
  1. Delete every `Japanese Output Discipline` 禁止表現 (hedge / suggest-直訳 / 確認伺い / 後送り); replace with the action itself or a numeric/conditional statement.
  2. Compress verbose phrasing; replace adjectives/adverbs with numbers or facts (`Japanese Output Discipline` 圧縮 / 具体性).
  3. Re-confirm BLUF and one topic sentence per paragraph.
  4. Delete any change-narration that leaked into the artifact (reordering notes, "per feedback…", version-diff parentheticals in headings) — per `No change-narration in the deliverable`; it belongs in chat / PR-comment / commit, not the document.
  **The trigger is whether the artifact is written to a file**: an artifact that goes to a file (report, analysis, proposal, spec) goes through the `/writing` skill. An inline report that fits in chat does not spawn it — self-apply, and `Read` `~/.agents/skills/writing/references/phrases.md` + `structures.md` to check against the full lists rather than from memory. This line coincides with the existing "over ~30 lines / will be reused → write it to a file" rule, so there is no per-case judgement. Single-line factual answers are exempt. Origin: issue #640 (inline reports moved to self-apply); 2026-09-10 — three sessions asked whether `/writing` had been applied at all (「文章としてとても読みにくいですね」), so file-bound artifacts went back through the skill.

## Session Retrospective

After 3+ commits, launch `session-retrospective` agent in background. `/retro` is the manual entry. "Blocked on manual" trigger covered in Behavioral Principles. Retro findings are persisted in full to the session's memory MCP on return (per-proposal `knowledge` notes + a session hub `episode`, linked by a shared retro-key marker in the content) — before and regardless of user selection. Only user-approved proposals are implemented into CLAUDE.md / `~/.agents/AGENTS.md` / rules / hooks / skills; adoption decisions (adopted/rejected) are revised back onto the saved notes.

## Compaction

Before compacting, preserve: current plan state, modified file paths, test commands, AskUserQuestion decisions. Write the active plan to its plan file with approved / in-progress / remaining items. On resume, read the plan file first.

**Malformed tool call recovery**: 2+ malformed errors in one session = context saturation: summarize working state (done / in-progress / next step) and propose `/compact` before continuing heavy work.

## Knowledge Persistence

See @~/.claude/docs/knowledge-persistence.md
