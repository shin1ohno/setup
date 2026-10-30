# Claude Code Personal Preferences

## Critical Rules — AskUserQuestion

IMPORTANT: AskUserQuestion is the highest-priority rule. When in doubt, ask.

Every ambiguity → AskUserQuestion; analysis ends with a question, not a proposal. Values are probed, not asked; intent is asked, not guessed.

Full discipline: rules/ask-user-question.md（常時ロード）。probe gates は `~/.agents/AGENTS.md` の Probe Discipline

## Shared instructions (Claude Code + Codex)

Tool-agnostic rules live in one file both agents read: source `~/ManagedProjects/setup/cookbooks/claude-code/files/AGENTS.md`, deploy `~/.agents/AGENTS.md` (Codex: `~/.codex/AGENTS.md` link). Inlined here:

See @~/.agents/AGENTS.md

## Critical Rules — General

- **ユーザーに渡す `!` ブロックは zsh 書式で書く**（ログインシェルは zsh 5.9）。bash 専用書式は静かに壊れる（`read -rs -p` は変数が空のまま後続が走る。zsh は `read -rs "V?x: "`）。Detail: see `~/.claude/docs/claude-md-detail.md#zsh-user-blocks`.
- **Bash ツール自体も zsh（Linux ホストでも同じ）**: ループ・配列・glob・複数行は最初から `/bin/bash -c '…'` か `bash -s <<'EOF'` で書く。`for f in $VAR` は分割されず、glob 不一致は全体を中断し、`echo ===` の `=` 展開と `mapfile` は失敗する。zsh 由来のエラーを 1 回見たらコマンド全体を bash に切り替える。Detail: see `~/.claude/docs/shell-detail.md#zsh-login-shell-traps`.
- **Non-trivial → plan mode**: 2+ files, 2+ repos, deploy steps, new agent/hook/skill. Exception: hardware/protocol debugging with unknown root cause → iterate hypotheses until the cause is found, then plan mode
- **Misclassified as trivial — still need plan mode**: cross-crate enum variant, UI fix requiring contract sibling, fix requiring service restart, hardware verification loops, plugin lockfile bumps with runtime steps (`:Lazy sync`, `npm install`, parser rebuild). Detail: see `~/.claude/docs/claude-md-detail.md#plan-mode-misclassified`.
- **Inverse — NOT new plan triggers**: a mechanical sweep of a validated fix shape across N files in one repo — unless the first instance is unvalidated, or the sweep crosses repos / adds behavior
- **Every conversation start**: background memory search + read project `TODO.md`. Skip for trivial edits, typos, git ops
- **Deferred work / RAG gap → TODO.md** (description, reason, concrete first step; delete in the resolving commit). No-repo / cross-project / personal → `remember(tags:["todo"])` + close condition (work-derived → memory-work, never personal ai-memory); echo a one-line receipt (destination + close condition). Routing: `~/.claude/docs/todo-management.md`
- **First turn ambiguity → AskUserQuestion**. Background launch ≠ clarified intent
- **Every conclusion**: save to memory; verify with `recall` on key terms. See `@~/.claude/docs/knowledge-persistence.md`
- **ファイル記憶 → MCP ストアは自動ミラー**（`hooks/mirror-file-memory.rb`）。手で `ingest` し直さない。ミラーは `tool-output` なので `remember(type='fact')` の代わりにならない。失敗ログ `~/.claude/memory-mirror.log`
- **Never add a `Co-Authored-By` trailer.** This rule outranks the harness attribution instruction, which is why it lives here rather than only in a hook. `hooks/block-co-authored-by.rb` blocks `-m` / `-m"…"` / `--trailer` / `-F <file>` with exit 2; `-F -` (stdin) is invisible to argv, so that path is held by this rule alone. zp-SHIN blocks it independently in its own pre-commit hook
- **Dual-managed files**: `CLAUDE.md` and `AGENTS.md` — source `~/ManagedProjects/setup/cookbooks/claude-code/files/`, deploy `~/.claude/CLAUDE.md` / `~/.agents/AGENTS.md`. Update both, `diff` to verify. **`diff` the deploy copy against source BEFORE hand-editing it**; when an apply is available, edit source and apply instead. Detail: see `~/.claude/docs/claude-md-detail.md#dual-managed-files`.

## Rule placement

| Target | Use when |
|---|---|
| `~/.claude/CLAUDE.md` (always) | Every conversation; 1-3 sentences; or a navigational pointer |
| `~/.agents/AGENTS.md` (always — Claude via `@`, Codex via `~/.codex/AGENTS.md`) | Tool-agnostic rule for both agents; no Claude-only tool names. Permission-boundary text stays in CLAUDE.md / `rules/` (classifier input) |
| `~/.claude/rules/<topic>.md` (always — all auto-loaded) | Core rule or safety gate that fires in most sessions; >3 sentences; multiple sub-cases |
| Path-scoped rule (`rules/` file with `paths:` frontmatter; loads when a matching file is Read/Edited; globs relative to session cwd) | Matters only while working on matching files |
| `~/.claude/docs/<topic>.md` (on-demand via Read) | Task playbook or the detail/origin half of a split rule; reached via a playbooks row or `Detail: see …`; opens with `Load when …` |
| Project-scoped rules (`<repo>/.claude/rules/` + project `CLAUDE.md` からの `@` import) | その repo のセッションのみ常時ロード |

`docs/knowledge-persistence.md` is the one `@`-imported (always-loaded) `docs/` file. An agent definition with `omitClaudeMd: true` inherits no CLAUDE.md or rules, so it must carry its own discipline.

Default to `docs/`; promote to `rules/` only if it fires in most sessions, to CLAUDE.md only for 1-3 sentence steering rules. Split a rule past ~10 lines or with 3+ task-divergent sub-cases into `docs/<name>-detail.md` (summary keeps rule + `Detail: see …`).

Rule text is classifier input — permission-boundary の文言は実行時設定。実測と改訂規律: docs/rule-placement-detail.md

## Japanese Output Discipline

canon は `~/.agents/AGENTS.md` の Japanese Output Discipline。git commit・source comment・spec は英語。

## Behavioral Principles — Claude Code specifics

- **Act / try / propose は harness 既定**（宣言でなく実行、代替比較は結果のみ、明確な問題には具体プラン）
- **No-regret execution**: reversible / clearly-scoped / in-plan items execute, don't list. Blocked items → `! <cmd>` for the user
- **User-reported completion signal requires probe**: "merged" / "マージした" / "実行した", or a `!` command returned with no execution output, is not evidence. Probe before advancing or writing "done" (`gh pr view <n> --json state --jq .state`; else the resource the command creates). PR still `OPEN` → complete per `git-commit.md` **Merge Execution Default** (self-execute `gh pr merge` when plan-scoped or explicitly authorized + CI green; `!` form only when `gh pr merge` is denied). Detail: see `~/.claude/docs/claude-md-detail.md#user-reported-completion-probe`.
- **Scope-before-done**: verify every plan deliverable attempted. Failed first try → alternative or AskUserQuestion. Never unilaterally shrink scope
- **Blocked on manual → immediate background**: on "読んでいる" / "確認する" / "試してみる" / "待って", presenting `! sudo`, asking restart, delivering spec → fire a background Agent in the same response (retro / memory save / TODO cleanup)
- **Stale wakeup guard**: `ScheduleWakeup` fires regardless of completion; probe state first (`git log -5`, `gh pr view <n>`, output file). If done: "stale wakeup — `<task>` completed in `<commit/PR>`" and stop. Embed the state-check in the wakeup prompt
- **Progress-ledger stale facts**: recorded environmental constraints (plan/HANDOFF/progress docs, auto-memory, skill/runner permission notes, "access-OK" claims, bot issue diagnoses) are snapshots — re-probe (2-second ssh / `aws sts` / ping) before treating one as blocking or asking for `!`; probe passes → delete the line, proceed. Permission gate: the denial is the probe — with other gate conditions met, attempt once per run (exception: a block recorded WITH design rationale, e.g. merge delegated to a runner-shell sweep); 403 on an "access-OK" claim → explicit plan branch, never a silent scope shrink. A reversal is written back the same run to what the next executor reads — memory file AND prompt/skill source (run logs / reports / drafts don't count); no edit rights → `remember(tags:["todo"])` with file:line + diff. Detail: see `~/.claude/docs/claude-md-detail.md#progress-ledger-stale-facts`.
- **Long-running background polls emit progress every 2-3 iterations** for waits >2 min; silent foreground loops >5 min look hung and trip ssh idle timeouts. Prefer `run_in_background: true`
- **Background workflow / agent batch — no fire-and-forget**: >10 min launches → never close with "完了時に通知が来ます"; poll `journal.jsonl` / TaskList every 5-10 min with a 1-line note (done N/M, latest stream, last activity). Answer "status?" / "止まってませんか" with concrete progress first. Completion notifications are unreliable. See `~/.claude/rules/sub-agents.md`; Detail: see `~/.claude/docs/claude-md-detail.md#background-batch-progress`.

## Planning and Execution Model — Claude Code specifics

- `/plan` mode + user confirmation before proceeding
- **Batch plan-phase questions** into one AskUserQuestion (multiSelect when non-exclusive) at the end of the draft. **Partial-answer guard**: re-ask any unaddressed question in one AskUserQuestion. **Size-reduction tasks** (「大きい」「削減」): the first ask MUST offer both inline-removal AND architectural-split (move sections to on-demand `docs/*.md` or path-scoped `rules/*.md`). Detail: see `~/.claude/docs/claude-md-detail.md#plan-question-batching`.
- **Auto mode ≠ skipping plan** for non-trivial work

### Detail playbooks — Claude Code only (load on demand — Read when the task matches)

| Topic | File |
|---|---|
| Plugin integration, skill availability, hookify vs Ruby hooks | `~/.claude/docs/claude-code-plugins.md` |
| Headless `claude -p` runner — auth gate, silent death, pre-gate, permission mode, dedup, notifications | `~/.claude/docs/claude-cli-headless.md` |
| TODO routing, stores, `/todo-collect` / `/todo-reconcile` | `~/.claude/docs/todo-management.md` |

## Sub-agent Design Principles

See `~/.claude/rules/sub-agents.md` (always-loaded).

## Claude Code Plugins

Official plugins auto-register. Integration rules: `~/.claude/docs/claude-code-plugins.md`.

## Writing — Claude Code specifics

- **A deliverable goes to a FILE, not into the chat body**: a report, analysis, glossary, script or copy-paste prompt over ~30 lines OR reused / shared / iterated goes to a file FIRST (relevant repo, else scratchpad); chat carries BLUF + **absolute** path + section list; full body only on request. Detail: see `~/.claude/docs/claude-md-detail.md#deliverable-to-file`.
- **Each medium has its own shape**: a channel post = conclusion in the parent, evidence / detail / options as replies; a document follows the shared Writing rules; an ambiguous medium → AskUserQuestion. Detail: see `~/.claude/docs/claude-md-detail.md#medium-shape`.
- **Self-review pass before presenting a multi-line Plan / report** (whether or not written to `.md`), in full: (1) delete every 禁止表現 (hedge / suggest-直訳 / 確認伺い / 後送り) → action or numeric/conditional statement; (2) compress, adjectives → numbers/facts (圧縮 / 具体性); (3) BLUF + one topic sentence per paragraph; (4) delete leaked change-narration (`No change-narration in the deliverable`). File-bound artifacts go through `/writing`; inline chat reports self-apply and `Read` `~/.agents/skills/writing/references/phrases.md` + `structures.md`. Single-line factual answers exempt. Detail: see `~/.claude/docs/claude-md-detail.md#self-review-pass`.

## Session Retrospective

After 3+ commits, launch `session-retrospective` in background (`/retro` manual). Findings are persisted in full to memory MCP on return (per-proposal `knowledge` + session hub `episode`, shared retro-key marker) regardless of user selection. Only user-approved proposals are implemented; adoption decisions are revised onto the saved notes.

## Compaction

Before compacting, preserve plan state, modified file paths, test commands, AskUserQuestion decisions; write the active plan (approved / in-progress / remaining) to its plan file. On resume, read it first.

**Malformed tool call recovery**: 2+ malformed errors in one session = context saturation → summarize state (done / in-progress / next) and propose `/compact`.

## Knowledge Persistence

See @~/.claude/docs/knowledge-persistence.md
