# Claude Code Personal Preferences

## Critical Rules — AskUserQuestion

IMPORTANT: AskUserQuestion is the highest-priority rule. When in doubt, ask.

Every ambiguity → AskUserQuestion; analysis ends with a question, not a proposal. Values are probed, not asked; intent is asked, not guessed.

Full discipline (examples, fallbacks, probe gates): rules/ask-user-question.md（常時ロード）

## Critical Rules — General

- Japanese output (style: "Japanese Output Discipline" below). English for git commits, source comments, spec docs. GitHub issue/PR description prose is Japanese too (section headings like `## Summary` / `## Test plan` stay English); match repo convention if the recent `gh issue/pr list` history is clearly English
- **AWS/Terraform 作業は docs/aws-iam.md を先に読む**（terraform apply は main からのみ、SSM/KMS ゲートは実ホストで probe）
- **Non-trivial → plan mode**. Non-trivial = 2+ files, 2+ repos, deploy steps, new agent/hook/skill. Exception: hardware/protocol debugging with unknown root cause → hypothesis iteration until cause found, then plan mode
- **Misclassified as trivial — still need plan mode**: cross-crate enum variant, UI fix requiring contract sibling, fix requiring service restart, hardware verification loops, plugin lockfile bumps with runtime steps (`:Lazy sync`, `npm install`, parser rebuild). Origin: 2026-05-01 AstroNvim ^5→^6 missed cross-machine cleanup
- **Inverse — NOT new plan triggers**: a mechanical sweep applying a validated fix shape across N files in one repo. Trigger plan mode only if first instance not yet validated, or sweep crosses repos / adds new behavior
- **Every conversation start**: background memory search + read project `TODO.md`. Skip for trivial edits, typos, git ops
- **Deferred work / RAG gap → TODO.md** with description, reason, concrete first step. Delete the entry in the resolving commit. No-repo / cross-project / personal TODOs → memory `remember(tags:["todo"])` + close condition (work-derived → memory-local, never personal ai-memory); echo a one-line receipt (destination + close condition) after every capture. Full routing + collect/reconcile loops: `~/.claude/docs/todo-management.md`
- **First turn ambiguity → AskUserQuestion**. Background launch ≠ clarified intent
- **Every conclusion**: save to memory; verify with `recall` on key terms. See `@~/.claude/docs/knowledge-persistence.md`
- **Every meaningful unit of work**: commit immediately
- **Dual-managed file**: source `~/ManagedProjects/setup/cookbooks/claude-code/files/CLAUDE.md`, deploy `~/.claude/CLAUDE.md`. Update both, `diff` to verify

## Rule placement

When adding or extending a rule, place it by these criteria:

| Target | Use when |
|---|---|
| `~/.claude/CLAUDE.md` (always loaded) | Applies every conversation; fits in 1-3 sentences; or is a navigational pointer |
| `~/.claude/rules/<topic>.md` (always loaded — every rules/ file is auto-loaded) | Broadly-applicable core rule or load-bearing safety gate that fires in most sessions; >3 sentences; multiple sub-cases |
| `~/.claude/docs/<topic>.md` (on-demand — loaded via Read, NOT auto-loaded) | Task-specific playbook, or the detail/origin half of a split rule. Reached via a CLAUDE.md "Detail playbooks" row or an inline `Detail: see …` pointer from its always-loaded summary. Open with a `Load when …` trigger line |
| Project-scoped rules (`<repo>/.claude/rules/` + project `CLAUDE.md` からの `@` import) | その repo のセッションのみ常時ロードするルール |

`docs/knowledge-persistence.md` is the one `docs/` file still `@`-imported (so always-loaded despite living in `docs/`); everything else in `docs/` is genuinely on-demand.

Default to `docs/` (on-demand). Promote to `rules/` only when the rule genuinely fires in most sessions; promote to main CLAUDE.md only for 1-3 sentence steering rules.

When extending an existing rule, keep it in place unless cumulative size grew past ~10 lines or 3+ sub-cases diverge by task type — then split the detail half into a `docs/<name>-detail.md` (always-loaded summary keeps the rule statement + a `Detail: see …` pointer).

Rule text is classifier input — permission-boundary の文言は実行時設定。実測と改訂規律: docs/rule-placement-detail.md

## Japanese Output Discipline

日本語出力の canon は rules/japanese-output.md（常時ロード）。git commit・source comment・spec は英語のまま。

## Behavioral Principles

- **Act / try / propose は harness 既定**（宣言でなく実行、代替比較は黙って結果のみ、明確な問題には具体プラン）— 詳細 4 bullet は 2026-08-17 監査で削除（モデル native 化）
- **No-regret execution**: reversible / clearly-scoped / in-plan items execute, don't list. Blocked items → present as `! <cmd>` for user
- **Zero-hedge on observable problems**: observed error/timeout → investigate and report fix plan. Banned: hedge ("might need"), suggest ("worth considering"), ask ("対応しますか？"), defer ("次回確認できます"). Replace with the action or its result
- **No terminal speculation**: don't close with "should happen within X" — poll observable state (`gh pr list`, `gh run list`) in the same turn. 外部の自律ループ（launchd/cron/CI スケジューラ）への pickup 委任も同じ — 「次サイクルで拾われます」と書く前に、同一 turn で liveness を probe する（kill-switch sentinel の有無・`launchctl list`・ログ最終行 timestamp）。Origin: 2026-06-27 64f6c5ef — kill-switch ON + LaunchAgent 未ロードのまま pickup を約束
- **User-reported merge signal requires probe**: "merged" / "マージした" → `gh pr view <n> --json state --jq .state` before advancing. If `OPEN`, complete the merge per `git-commit.md` **Merge Execution Default** (self-execute `gh pr merge` when plan-scoped or explicitly authorized + CI green — it's allow-listed, so don't reflexively present `! gh pr merge`; present the `!` form only when `gh pr merge` is denied). Origin: 2026-05-06 retro 2x built on un-merged PRs
- **Issue-completion self-comment**: when a non-trivial issue-originated investigation/fix completes, self-comment the outcome (what was done, verification, residual risk/tasks) on the originating issue — PR auto-close is not a completion record. Exception: bot-loop issues with their own comment protocol (self-heal etc.)
- **Verify-before-done**: observe receiving-system state, not your code's "success" log. Build observation tool first if not visible from source. See `~/.claude/rules/debugging.md`
- **Verify functional state, not deployment artifacts**: `systemctl is-active` (artifact) vs the next-elapse from `systemctl status <name>.timer` / `list-timers` (functional — `show --property=Trigger` is NOT a valid check, it prints empty for armed and dead timers alike; see `~/ManagedProjects/setup/.claude/rules/infrastructure.md`). Layer-specific examples: `~/ManagedProjects/setup/.claude/rules/infrastructure.md`, `docs/docker-compose.md`, `docs/tailscale.md`. Origin: PR #253 → #257 → #259 — 3 iterations from artifact-shaped verification
- **Scope-before-done**: verify every plan deliverable attempted. Failed first try → retry alternative or AskUserQuestion. Never unilaterally shrink scope
- **Hotfix layering**: evaluate change frequency vs resource recreation; place fix at the appropriate layer, not where it was edited on the server
- **Blocked on manual → immediate background**: signals — "読んでいる" / "確認する" / "試してみる" / "待って", presenting `! sudo`, asking restart, delivering spec. Fire background Agent in the same response (retro / memory save / TODO cleanup)
- **Stale wakeup guard**: `ScheduleWakeup` fires regardless of completion. Probe state (`git log -5`, `gh pr view <n>`, output file). If done: "stale wakeup — `<task>` completed in `<commit/PR>`" and stop. Embed state-check at the start of the wakeup prompt
- **Progress-ledger stale facts**: environmental constraints recorded in plan.md / HANDOFF.md / progress docs (SSH failures, auth expiry, network unreachability, tool unavailability) are snapshots from the session that wrote them — re-probe before treating one as still-blocking, especially when it would trigger user `!` round-trips: `ssh -o ConnectTimeout=5 root@<host> hostname`, `aws sts get-caller-identity --profile P`, `ping -c1 -W2 <IP>`. If the probe succeeds, delete the stale line from the doc and proceed. Do not ask the user to run `!` for something a 2-second probe disproves. Sources are not limited to progress docs — auto-memory files, skill / runner-prompt permission notes, recorded "access-OK" claims, and an autonomous bot's own issue-tracker diagnosis (self-heal / monitor-alert root-cause hypotheses are snapshots too — the self-heal bot's diagnosis was re-verified live 4 days later before acting, 2026-07-11) are the same snapshot class. For a permission gate, the denial itself is the cheapest probe: when the other gate conditions are met, attempt once per run instead of skipping on the record alone (exception: a block recorded WITH its design rationale, e.g. merge deliberately delegated to a runner-shell sweep); on "access-OK" claims, re-probe before use and surface a 403 as an explicit plan branch, never a silent scope shrink. When an attempt reverses the record, write the reversal back to the record's SOURCE — the memory file AND the prompt/skill source file — in the same run; updating only one copy leaves the next scheduled run re-reading the stale claim (observed 2026-07: reversal seen 7/3, written back 7/6; a sibling run skipped a merge-ready PR within the hour on the stale note). Origin: 2026-06-13 propagated stale plan.md ssh-fail line unverified.
- **Long-running background polls emit progress every 2-3 iterations** for waits >2 min. Silent foreground loops >5 min look like hangs + trigger ssh idle timeouts. Prefer `run_in_background: true`
- **Background workflow / agent batch — no fire-and-forget**: >10 min background launches → don't close the turn with "完了時に通知が来ます"; poll `journal.jsonl` / TaskList every 5-10 min and emit a 1-line progress note (done N/M, latest completed stream, last-activity time). Answer a user's "status?" / "止まってませんか" with concrete progress before resuming work. A completion notification is not a reliable terminal signal — sub-agents can die silently (rate-limit / Connection closed). Detail: `~/.claude/rules/sub-agents.md`. Origin: 2026-07 aa4b0e75 (status? ×3) / 29d690f1 (30 min silent)
- **Step-by-step verification when user is present**: when an experimental change or unfamiliar flow needs verification AND the user is interactively present, present a numbered checklist of discrete probes / commands BEFORE running anything end-to-end. The user can stop at any step if assumptions diverge; e2e from the first probe loses that off-ramp. Origin: 2026-05-11 e2e-first apply missed IAM scope mismatch surfaceable on probe 2.
- **Domain term verification before propagation**: when another agent (Slack response, sub-agent, web search summary) provides a domain definition (KPI naming, metric formula, business term), verify against canonical source (textbook, wiki, official docs) before propagating in your analysis or report. Origin: 2026-05-19 propagated a Slack agent's wrong ATPU/ARPU definition into a dashboard.
- **Event mechanism check before computing conversion rates**: for any funnel analysis (especially BE / app events like reward grant, status change, notification fired), verify with the feature team (Slack / Confluence / source code) whether each stage is `user-action` (TAP / SCREEN_DISPLAY / form submit) / `passive` (display) / `automatic` (backend-triggered) / `policy-driven` (eligibility criteria met). A "conversion rate" between non-user-action stages is meaningless. Origin: 2026-05-19 framed S3→S5 as user conversion, but S5 reward is auto-granted.
- **Selection bias survey at analysis design time**: when designing cohort definitions for treatment/control comparisons, list at design time (BEFORE running queries) the potential biases of each cohort: (a) selection on outcome (cohort defined by what we're measuring), (b) engagement bias (cohort over-represents active users), (c) treatment contamination (control includes some treatment), (d) period bias (window length effect). Each bias should have a stated mitigation or acknowledged caveat. Origin: 2026-05-19 3 rounds of Control proxy redesign from post-hoc bias discovery.
- **Denominator and claim-source tracking in analysis reports**: カバレッジ・飽和・リーチの主張は権威あるコホート/experiment テーブルから母集団分母を取得し、対象値÷母集団の比率を明示してから書く — 絶対数の大きさは分母の代わりにならない。レポート散文中の説明要因・因果クレーム（「X が律速」等）にも数値と同じソース追跡を課し、「実測/仮説」をタグ付けして probe 可能な仮説は出荷前にクエリ確認する。Origin: 2026-06/07 zp-SHIN — 露出 2.35M を分母なしで提示（実際は介入群 11.6M の ~20%）、skill prose の未検証仮説「アプリ普及が不完全」が実測 75-92% と矛盾。**仮定係数の後送り注記は違反**: 仮定係数（リーチ率・分布・普及率）を表に置いてから「この数値の限界」を注記し実測を次ステップに回すのは違反 — 表を出す前に権威ある DWH / コホートテーブルで実測する（注記＋後送りは compliance ではない。Origin: 2026-07-21 — 均一 18.4% リーチ仮定で SAM/SOM 表を出荷、実測したら年齢帯で最大 18 倍乖離）。**増分更新の棚卸し**: 増分更新・検証/裏取りパスでは前版と行数 diff を取り、未確認行は種別マーク（確=裏取り済/概=推計/要=要データ）付きで残す（黙って落とさない）。既存全節の as-of/データ窓も棚卸しする（Origin: 2026-07-21 — 裏取りパスで約 80 イベント表が黙って 20 行に縮小）。

## Planning and Execution Model

- `/plan` mode + user confirmation before proceeding
- **Batch plan-phase questions** into one AskUserQuestion (multiSelect when non-exclusive) at the end of the plan draft. **Partial-answer guard**: count answered questions; re-issue a single AskUserQuestion for any unaddressed. **File compression/refactor tasks**: when the user signals size dissatisfaction (「大きい」「40k とかある」「削減」), the initial AskUserQuestion MUST include both inline-removal AND architectural-split (move sections to on-demand `rules/*.md`) options. Discovering the split option after the user already answered inline-only forces a 2-turn plan revision. Origin: 2026-05-11 CLAUDE.md trim — split option surfaced too late.
- **After plan approval, execute autonomously** — no per-step permission. PR is the reviewable artifact (branch → implement → test → commit → `gh pr create`)
- **Auto mode ≠ skipping plan** for non-trivial work
- **State archaeology before reusing a TF resource type**: `terraform state show`, `aws iam get-user-policy`, `pct config <existing-vmid>`, `cat cookbooks/<existing>/default.rb`. Origin: 2026-05-06 CT 111 lost ~45 min to 2 blockers visible from a 2-min archaeology

### Detail playbooks (load on demand — Read when the task matches)

These are `docs/` files (not auto-loaded). `Read` the file when the task matches its trigger. Always-loaded `rules/` summaries may point to their own `docs/<name>-detail.md` inline — those are not indexed here.

| Topic | File |
|---|---|
| AWS / IAM / SSM / KMS / Terraform — drift 判定、apply branch gate、実ホスト probe | `~/.claude/docs/aws-iam.md` |
| mitamae/Ruby・shell script・infra ops の常時ルール（setup プロジェクト外から必要時） | `~/ManagedProjects/setup/.claude/rules/{ruby,shell,infrastructure}.md` |
| Rust workspace commit gate (fmt/build/test/clippy), Cargo.lock staging, crates.io token scopes, cross-platform build gates | `~/.claude/docs/rust.md` |
| Docker Compose ops — branch-dep pre-deploy check, notify `--force-recreate`, UDP host-net, up -d exit-1 triage | `~/.claude/docs/docker-compose.md` |
| Pre-PR cookbook implementation checklist (IP literal / healthcheck quoting / bind-mount UID / UDP host-net) | `~/.claude/docs/cookbook-prs.md` |
| Homebrew→mise / direct-download migration — 5-check upstream verification | `~/.claude/docs/mise-migration.md` |
| iOS build (XcodeGen + Rust UniFFI): fresh-Mac prereqs, keychain, deploy probe | `~/.claude/docs/ios-build.md` |
| Kibana Lens visualization / saved-object NDJSON gotchas | `~/.claude/docs/kibana-lens.md` |
| RemoteTrigger API field reference + scheduled-trigger design | `~/.claude/docs/remote-trigger.md` |
| Tailscale `accept-routes` vs LAN-supernet routing conflict | `~/.claude/docs/tailscale.md` |
| Frontend (Next.js / Vite) dev-server / HMR gotchas | `~/.claude/docs/frontend-dev.md` |
| Data-collection failure-escalation + transient-retry ladder | `~/.claude/docs/data-collection.md` |
| Weave protocol publish → feedback shape contract | `~/.claude/docs/weave-protocol.md` |
| Elasticsearch query/index layer (`dense_vector` / kNN / mappings) gotchas | `~/.claude/docs/elasticsearch.md` |
| Adding an OAuth-protected MCP service to mcp.ohno.be | `~/.claude/docs/mcp-deployment.md` |
| Neovim (AstroNvim) config repo: Lazy sync / plugin lockfile gotchas | `~/.claude/docs/neovim.md` |
| release-plz failure-mode checklist (secrets, token scopes, workflow config) | `~/.claude/docs/release-plz.md` |
| FFI boundary (UniFFI Rust↔Swift / JNI / WASM) encoding audit at plan time | `~/.claude/docs/ffi-audit.md` |
| Claude Code plugin integration rules — skill availability check, hookify vs Ruby hooks, plugin-vs-cookbook | `~/.claude/docs/claude-code-plugins.md` |
| PVE LXC operational gotchas — unprivileged bind-mount UID mapping, `pct exec` non-TTY, Docker-in-LXC design gate | `~/.claude/docs/pve-lxc-detail.md` |
| Headless / scheduled `claude -p` runner — auth-token gate, runner death / silent-failure detection, fail-closed pre-gate, permission-mode probe, re-dispatch dedup, notification channels | `~/.claude/docs/claude-cli-headless.md` |
| TODO capture routing, stores, collect / reconcile loops (`/todo-collect`, `/todo-reconcile`) | `~/.claude/docs/todo-management.md` |
| fractal node trees + plasma-wiki — agent config home not inherited, cost caps need an explicit model, `--scope` double-nesting, budget shape, wiki lint / naming traps, wave design | `~/.claude/docs/fractal-nodes.md` |
| GPG secret-subkey distribution to a headless host via a secret store — passphrase stripping via agent keygrip, `--batch` silent-drop detection, per-step checkpoints, rotation | `~/.claude/docs/gpg-key-distribution.md` |

## Sub-agent Design Principles

See `~/.claude/rules/sub-agents.md` (always-loaded via `rules/`; no `@`-import needed).

## Claude Code Plugins

Official plugins auto-registered; most self-describe triggers. See `~/.claude/docs/claude-code-plugins.md` (on-demand — Read when integrating a plugin) for plugin-vs-cookbook integration rules.

## Writing

Applies to any prose output — formal docs AND chat replies (structural enforcement scales with length; philosophy + Japanese rules are constant).

- **Reader / BLUF / length は harness 既定** — 結論先行・読者に合わせた長さ（詳細は 2026-08-17 監査で削除）
- **Chat ≠ full Pyramid**: 1-2 levels is fine (constraint is "topic sentence per paragraph"), not the strict 3-level hierarchy.
- **Reference, don't reproduce**: cite "see `Japanese Output Discipline`" or "see `rules/debugging.md`" instead of pasting protocol text inline — long extracted text is reading-cost with no marginal utility.
- **No change-narration in the deliverable**: a report / document / proposal / spec contains only reader-facing content — never meta-commentary about how it was authored, ordered, or revised. Editing rationale and reordering / version-diff notes (a heading like `打ち手（North Star を上に、制約対応を下に）`, "per your feedback I moved X above Y", "この節を最上位に移動") belong in the chat reply, crit / PR comment, or commit message — not in the artifact's headings or body. The reader reconstructs *what the document says*, not *how you built it*. Origin: 2026-07 — restructured a proposal per crit feedback and embedded the reviewer's reordering instruction verbatim into a section heading.
- **A deliverable goes to a FILE, not into the chat body**: a report, analysis, glossary, script, or copy-paste-ready prompt that exceeds ~30 lines OR will be reused / shared / iterated on is written to a file FIRST — a sensible path inside the relevant repo, or the scratchpad when it belongs to no repo — and the chat reply carries only BLUF + the **absolute** path + the section list. Paste the full body into chat only when the user asks for it. Always give an absolute path (a relative one does not resolve against the user's cwd — cf. `~/ManagedProjects/setup/.claude/rules/shell.md` "User-run block self-containment"). This is not the same rule as `sub-agents.md`'s "Synthesis Stage — Pass Data by Path", which governs agent-to-agent handoff; this one governs the user-facing deliverable. Origin: 2026-07-22〜07-30 — 「ファイルに書き出して」/「フルパスで」を 8 セッションで 11 回言わせ、うち 1 件は同一セッション 2 回目の「ファイルに書き出してって言いませんでしたか？」だった。
- **Domain-heavy documents**: bulk terminology edits follow ~/.claude/docs/domain-writing.md (Load when editing domain-heavy reports or terminology at scale).
- **Japanese prose**: clarity over politeness; the canonical style rules are the `Japanese Output Discipline` section above (single source of truth — do not restate).
- **Self-review pass before presenting a multi-line Plan / report** (Plan, analysis, retro, research summary — *whether or not* it is written to `.md`): the bullets above are "while writing"; this is a mandatory pass over the finished draft *before* it reaches the user. Not optional polish — apply the discipline in full, no half-measures:
  1. Delete every `Japanese Output Discipline` 禁止表現 (hedge / suggest-直訳 / 確認伺い / 後送り); replace with the action itself or a numeric/conditional statement.
  2. Compress verbose phrasing; replace adjectives/adverbs with numbers or facts (`Japanese Output Discipline` 圧縮 / 具体性).
  3. Re-confirm BLUF and one topic sentence per paragraph.
  4. Delete any change-narration that leaked into the artifact (reordering notes, "per feedback…", version-diff parentheticals in headings) — per `No change-narration in the deliverable`; it belongs in chat / PR-comment / commit, not the document.
  For a substantial draft, `Read` `~/.claude/skills/writing/references/phrases.md` + `structures.md` and check against the full lists rather than from memory. Do NOT spawn the 3-agent `/writing` skill for these inline reports — self-apply the same discipline. Single-line factual answers are exempt. Origin: issue #640.

## Session Retrospective

After 3+ commits, launch `session-retrospective` agent in background. `/retro` is the manual entry. "Blocked on manual" trigger covered in Behavioral Principles. Retro findings are persisted in full to the session's memory MCP on return (per-proposal `knowledge` notes + a session hub `episode`, linked by a shared retro-key marker in the content) — before and regardless of user selection. Only user-approved proposals are implemented into CLAUDE.md/rules/hooks/skills; adoption decisions (adopted/rejected) are revised back onto the saved notes.

## Compaction

Before compacting, preserve: current plan state, modified file paths, test commands, AskUserQuestion decisions. Write the active plan to its plan file with approved / in-progress / remaining items. On resume, read the plan file first.

**Malformed tool call recovery**: 2+ malformed errors in one session = context saturation: summarize working state (done / in-progress / next step) and propose `/compact` before continuing heavy work.

## Knowledge Persistence

See @~/.claude/docs/knowledge-persistence.md
