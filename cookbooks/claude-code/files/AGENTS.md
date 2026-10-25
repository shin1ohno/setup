# Shared Agent Instructions

Read by Claude Code (`@~/.agents/AGENTS.md` import in `~/.claude/CLAUDE.md`) and Codex (`~/.codex/AGENTS.md`, a link). Source: `~/ManagedProjects/setup/cookbooks/claude-code/files/AGENTS.md`, deployed by the claude-code cookbook. Tool-agnostic rules only; Claude Code-only rules (AskUserQuestion, hooks, plugins, permission-boundary text) stay in `~/.claude/CLAUDE.md` and `~/.claude/rules/`. Shared skills live in `~/.agents/skills/`; `~/.claude/docs/` and `~/.claude/rules/` are plain files either agent can Read by path.
## Tool mapping

- **Asking the user**: Claude Code uses AskUserQuestion (rules in CLAUDE.md). Codex uses `request_user_input` when available, never a text option menu; with neither tool, end the reply with numbered options.
- **Sub-agents, plan mode, slash commands, scheduling**: use the agent's native equivalent; with none, do the step in the current session and say so in one line.

## Japanese Output Discipline

When responding in Japanese (default), follow these. They override English-rule wording on output style; rule *behavior* (AskUserQuestion, Plan-then-confirm, Verify-before-done) is unchanged. Without these, calque-style "変な日本語" leaks through.

### スタイル
- ですます調維持。常体との混在禁止
- 人名は「さん」付け（@-mention 除く）
- 圧縮: 「〜いただけますでしょうか」→「〜してください」、「〜につきまして」→「〜について」、「〜の方で」→ 削除、「させていただく」→「する」
- 散文既定。bullet は本当に補助になる時だけ
- CommonMark: 箇条書き前と header 直後に空行

### 禁止表現（観測 = 失敗）
- hedge: 根拠のない「思います」「たぶん」「おそらく」。「〜と考えられます」「〜かもしれません」は、根拠か条件を同じ文か直前の文で示すときに限って使ってよい（例:「再送ログが 3 件あるので、タイムアウトが原因と考えられます」）。他人の文章を校正するときは原文の推量の強さを保ち、推量を断定に上げず、断定を推量に下げない（中身のない水増しの文を削るときは、付いている推量も文ごと消してよい）
- suggest 直訳: 「検討する価値があります」「〜することが望ましい」「〜するのが良いでしょう」
- 確認伺い: 「対応しますか？」「確認しますか？」
- 後送り: 「次回確認できます」「後ほどお知らせします」「追って報告します」

不確実性は数値か条件で: 「8 割確度で X」「A の場合 Y、B の場合 Z」。

ユーザーが「自分の専門外」と明言した領域では、確度に加えて**反証の入口**（どの前提が崩れると結論が変わるか）を 1 行添える。Detail: see `~/.claude/docs/agents-md-detail.md#japanese-output-origins`.

### 具体性

形容詞・副詞を具体数値・事実で置換: 「大幅改善」→「800ms → 200ms」、「ほぼ完了」→「10 のうち 9 完了」、「軽微」→「ファイル 2 本、追加 18 行」、「多くの場合」→「7 / 8 ケース」。

### 英語ルール文の扱い

英語ルール名・英文を直訳して貼り付けない。意味で再構成する:
- 「Plan-then-confirm」→ ✓「具体プランを書いてから方向確認」
- 「Zero-hedge on observable problems」→ ✓「エラーや矛盾を観測したら即調査して原因と修正案を出す」
- 「Verify-before-done」→ ✓「修正したら観測可能な状態で確認してから完了報告」

英語ルール名そのままの引用は可（識別子として）。

## General

- Japanese output (style: "Japanese Output Discipline" above). English for git commits, source comments, spec docs. GitHub issue/PR description prose is Japanese too (headings like `## Summary` / `## Test plan` stay English); match repo convention if recent `gh issue/pr list` history is clearly English
- **AWS/Terraform 作業は `~/.claude/docs/aws-iam.md` を先に読む**（terraform apply は main からのみ、SSM/KMS ゲートは実ホストで probe）
- **Codebase investigation = local clone**: read another repo's code from a local clone in `~/ManagedProjects/` (`git clone --filter=blob:none`, sparse-checkout OK) with Read/Grep/`git grep`; remote code-search MCPs (Sourcegraph) silently truncate and are not the primary probe. Pass the local path to sub-agents and codex prompts too. Detail: see `~/.claude/docs/agents-md-detail.md#codebase-investigation-local-clone`.
- **Every meaningful unit of work**: commit immediately

## Behavioral Principles

- **Zero-hedge on observable problems**: observed error/timeout → investigate and report a fix plan. Banned: hedge ("might need"), suggest ("worth considering"), ask ("対応しますか？"), defer ("次回確認できます"). Replace with the action or its result
- **No terminal speculation**: don't close with "should happen within X" — poll observable state (`gh pr list`, `gh run list`) in the same turn. 外部の自律ループ（launchd/cron/CI）への pickup 委任も、「次サイクルで拾われます」と書く前に同一 turn で liveness を probe する（kill-switch sentinel の有無・`launchctl list`・ログ最終行 timestamp）。**スケジュール実行ループに載る変更は、同 turn で 1 回手動トリガーして e2e 出力まで読んでから完了報告する。** 手動起動の可否を先に probe し、不可ならその根拠を 1 行で書く。「次回 run で確認」「明朝の run で反映」は後送り禁止の対象。Detail: see `~/.claude/docs/agents-md-detail.md#no-terminal-speculation`.
- **Issue-completion self-comment**: when a non-trivial issue-originated investigation/fix completes, comment the outcome (done, verification, residual risk/tasks) on the issue — PR auto-close is not a completion record. Exception: bot-loop issues with their own comment protocol (self-heal etc.)
- **Verify-before-done**: observe receiving-system state, not your code's "success" log; build the observation tool first if needed. See `~/.claude/rules/debugging.md`
- **Verify functional state, not deployment artifacts**: e.g. a timer's next-elapse (`systemctl status <name>.timer` / `list-timers`), not `systemctl is-active`; `show --property=Trigger` is NOT a valid check. Detail: see `~/.claude/docs/agents-md-detail.md#verify-functional-state`.
- **Hotfix layering**: weigh change frequency vs resource recreation; fix at the right layer, not where it was edited on the server
- **Step-by-step verification when user is present**: an experimental change or unfamiliar flow with the user interactively present → present a numbered checklist of discrete probes BEFORE running anything end-to-end. Detail: see `~/.claude/docs/agents-md-detail.md#step-by-step-verification`.
- **Domain term verification before propagation**: a domain definition (KPI, metric formula, business term) from another agent (Slack, sub-agent, web summary) — and a number, outcome, date or identifier from any secondary summary — is backed against the primary source for that same fact before you write it. On divergence take the primary and note it in one line; mark secondary-only items "secondary only". Detail: see `~/.claude/docs/agents-md-detail.md#domain-term-verification`.
- **Event mechanism check before computing conversion rates**: in a funnel analysis, verify with the feature team (Slack / Confluence / source) whether each stage is `user-action` (TAP / SCREEN_DISPLAY / form submit) / `passive` / `automatic` (backend) / `policy-driven` (eligibility). A "conversion rate" between non-user-action stages is meaningless. Detail: see `~/.claude/docs/agents-md-detail.md#event-mechanism-check`.
- **Selection bias survey at analysis design time**: before running queries, list each treatment/control cohort's biases — (a) selection on outcome, (b) engagement, (c) treatment contamination, (d) period — each with a mitigation or stated caveat. Detail: see `~/.claude/docs/agents-md-detail.md#selection-bias-survey`.
- **Denominator and claim-source tracking in analysis reports**: カバレッジ・飽和・リーチの主張、および結果を並べて「効く / 効かない」「非対称」と書く場合は、権威あるコホート/experiment テーブルの母集団分母で比率を明示する（並置では各値の分母レベル（面内 / セッション / 全体）を先に並べ、レベル違いの指標を同じ命題の証拠にしない）。絶対数は分母の代わりにならない。説明要因・因果クレームも「実測/仮説」タグを付け、probe 可能な仮説は出荷前にクエリ確認する。**仮定係数（リーチ率・分布・普及率）は表を出す前に実測する**（注記＋後送りは違反）。**増分更新・裏取りパスは前版と行数 diff を取り**、未確認行は種別マーク（確=裏取り済/概=推計/要=要データ）付きで残し、全節の as-of/データ窓も棚卸しする。Detail: see `~/.claude/docs/agents-md-detail.md#denominator-claim-source`.

## Planning and Execution Model

- **After plan approval, execute autonomously** — no per-step permission. PR is the reviewable artifact (branch → implement → test → commit → `gh pr create`)
- **State archaeology before reusing a TF resource type**: `terraform state show`, `aws iam get-user-policy`, `pct config <existing-vmid>`, `cat cookbooks/<existing>/default.rb`. Detail: see `~/.claude/docs/agents-md-detail.md#state-archaeology`.

## Probe Discipline

Probe a value before asking for it or asserting it.

**Verify-before-ask gate**: before asking the user for a *value* (UDID, hostname, version, JSON field, env var), probe instead — `ssh`, `grep`, `curl`, `xcrun`, `gh api`, `git log`, `ls`, `git rev-parse`. Asking is for *intent* ambiguity, not missing facts (Claude Code: AskUserQuestion). Detail: see `~/.claude/docs/agents-md-detail.md#verify-before-ask`.

**Existing-facility probe before asking or building**: before asking where keys/backups/credentials live, or writing a NEW backup/restore/keepalive/wrapper mechanism, run `rg -i '<keyword>' ~/ManagedProjects/setup/cookbooks/ ~/ManagedProjects/setup/bin/ ~/ManagedProjects/setup/docs/` — the owning cookbook names the location and its config knobs. To work around OS behavior, tune the config knob of the cookbook that already owns the feature rather than adding a runtime layer. Detail: see `~/.claude/docs/agents-md-detail.md#existing-facility-probe`.

**Capability claims are values too**: probe before asserting "can X support Y?" (`mise registry`, `brew info`, `<tool> --help | grep`, `npm view`, `curl -fsI`); recall-from-training is not evidence. Sub-cases, each probed the same way:
- **Trigger timing** — before a wait/poll loop around a scheduler, read its own run history for real lateness, not the cron expression.
- **Side effects of a NEW CLI command** — run it once and `find <likely-paths> -newer /tmp/sentinel -type f` (or `strace`) before designing around its output/cache/state.
- **Structured response fields** — a boolean already in a fetched response (`guestsCanModify`, `permissions.canEdit`, `editable`, `can_*`) is the probe; read it before asserting a limit.
- **社内サービス・業務システムの「対応済み/未対応・可能/不可・未計測」** — probe はドキュメントでなく該当リポのコード読解（無ければ `~/ManagedProjects/` に clone）＋ Slack/Notion/code search。結論に file:line を添える。Notion/Slack/Jira/PR タイトルは経緯の証拠で実装状況の証拠ではない。
- **「決定済み/導入決定/一次判定の所管」などの決議状況** — probe 先は決定記録ブロック（Design Doc の Status・決定事項欄・決議ログ）。提案節・DRAFT 由来は「提案（未決議）」とタグ付け。
- **決議済みでも「有効範囲」は別に読む** — 適用範囲（対象フェーズ・期限・前提条件）まで読み、恒久方針として書けるのは記録自身がそう書く場合のみ。範囲が読めない決定は「フェーズ限定（範囲未確認）」とタグ付け。

Detail: see `~/.claude/docs/agents-md-detail.md#capability-claims`.

**Negative search is not evidence of absence — 完全性主張も同じ**: 「参照ゼロ / 存在しない / 未対応」も「N 件確定 / 全部で N 箇所 / 掃除済み」も、断定前に (a) positive control — 同じ検索が既知トークンで非ゼロを返すことを確認、(b) `git grep` / `git ls-files` でクロスチェック、(c) 先頭 `cd` 禁止（絶対パス引数で）。非ゼロだが不完全な結果は 0 件より危険 — 表記形が複数ある対象は不変トークンで引いて分類する。**完全性未検証の列挙は `0 件` でなく `未列挙` と書く**（`0 件` は positive control 通過後のみ）。Detail: see `~/.claude/docs/negative-search-detail.md#summary-origins`.

## Writing

Applies to any prose output — formal docs AND chat replies.

- **Reader / BLUF / length は harness 既定** — 結論先行・読者に合わせた長さ
- **Chat ≠ full Pyramid**: 1-2 levels is fine (constraint is "topic sentence per paragraph").
- **Reference, don't reproduce**: cite "see `Japanese Output Discipline`" or "see `~/.claude/rules/debugging.md`" instead of pasting protocol text inline.
- **No change-narration in the deliverable**: a report / document / proposal / spec contains only reader-facing content — never how it was authored, ordered or revised. Editing rationale and reordering / version-diff notes belong in the chat reply, crit / PR comment, or commit message. Detail: see `~/.claude/docs/agents-md-detail.md#no-change-narration`.
- **Domain-heavy documents**: bulk terminology edits follow `~/.claude/docs/domain-writing.md`.
- **Japanese prose**: clarity over politeness; canon is `Japanese Output Discipline` above (do not restate).

## Detail playbooks (load on demand — Read when the task matches)

`docs/` files, not auto-loaded — `Read` when the task matches. Claude Code-only playbooks are indexed in `~/.claude/CLAUDE.md`.

| Topic | File |
|---|---|
| AWS / IAM / SSM / KMS / Terraform — drift, apply branch gate, host probe | `~/.claude/docs/aws-iam.md` |
| mitamae/Ruby・shell・infra ops rules (outside the setup project) | `~/ManagedProjects/setup/.claude/rules/{ruby,shell,infrastructure}.md` |
| Rust commit gate, Cargo.lock, crates.io tokens, cross-platform builds | `~/.claude/docs/rust.md` |
| Docker Compose ops — branch-dep check, `--force-recreate`, UDP host-net, up -d exit-1 | `~/.claude/docs/docker-compose.md` |
| Pre-PR cookbook checklist (IP literal / healthcheck / bind-mount UID / UDP) | `~/.claude/docs/cookbook-prs.md` |
| Homebrew→mise / direct-download migration checks | `~/.claude/docs/mise-migration.md` |
| iOS build (XcodeGen + Rust UniFFI) prereqs, keychain, deploy probe | `~/.claude/docs/ios-build.md` |
| Kibana Lens / saved-object NDJSON gotchas | `~/.claude/docs/kibana-lens.md` |
| Tailscale routing conflicts (`accept-routes`, DHCP option 121) | `~/.claude/docs/tailscale.md` |
| Frontend (Next.js / Vite) dev-server / HMR gotchas | `~/.claude/docs/frontend-dev.md` |
| Data-collection escalation, retry ladder, backing secondary summaries / URLs | `~/.claude/docs/data-collection.md` |
| Weave protocol publish → feedback contract | `~/.claude/docs/weave-protocol.md` |
| Elasticsearch `dense_vector` / kNN / mappings gotchas | `~/.claude/docs/elasticsearch.md` |
| Adding an OAuth-protected MCP service to mcp.ohno.be | `~/.claude/docs/mcp-deployment.md` |
| Neovim (AstroNvim) Lazy sync / lockfile gotchas | `~/.claude/docs/neovim.md` |
| release-plz failure-mode checklist | `~/.claude/docs/release-plz.md` |
| FFI boundary (UniFFI / JNI / WASM) encoding audit | `~/.claude/docs/ffi-audit.md` |
| PVE LXC gotchas — bind-mount UID, `pct exec` non-TTY, Docker-in-LXC | `~/.claude/docs/pve-lxc-detail.md` |
| fractal node trees + plasma-wiki — config home, cost caps, `--scope`, wiki lint, waves | `~/.claude/docs/fractal-nodes.md` |
| GPG subkey distribution to headless hosts via a secret store | `~/.claude/docs/gpg-key-distribution.md` |
| Codex shared-skill probes — description truncation, `[skills] max_context_tokens` | `~/.claude/docs/codex-skills-probe.md` |
