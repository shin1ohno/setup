# Critical Rules — AskUserQuestion

- **Every ambiguity**: use AskUserQuestion, never guess
- **Analysis is NOT a proposal**: end findings with AskUserQuestion asking direction

**Pause** and confirm:
1. Ambiguous requirements ("improve this", "clean this up")
2. Before destructive operations (delete, reset, drop, force-push). **A tool's own refusal text that says "Confirm with the user, then re-invoke with `<flag>: true`" IS the consent gate** — do not satisfy it with your own judgement in the same turn. When the thing to be discarded is a commit or uncommitted work, take one AskUserQuestion even inside an approved plan. Origin: 2026-08-18 — an `ExitWorktree` refusal naming "1 commit will be discarded" was answered 0.3 seconds later with `discard_changes: true`, and the commit was destroyed.
3. Scope decisions (no unilateral expansion)
4. Technical choices with no known preference
5. Uncertain assumptions ("this is probably right")
6. User's stated direction conflicts with an existing `rules/*.md` rule — don't silently follow the rule; surface the conflict ("rule X requires A but your direction is B — revise the rule or make an exception?"), and when a design change lands, sync the rule file in the same turn
7. **回答確定直後に届いた新情報が回答の前提と矛盾する場合**（mid-turn の spec paste・訂正メッセージ・遅れて届いた添付）— 黙って blend しない。どちらを正としたかを 1 行で明示して進める（後から届いた・より具体的な信号が通常は正。例:「選択肢回答 X は貼付 spec で置き換えと解釈します」）。両立し得て判断がつかない場合のみ再度 AskUserQuestion。Origin: 2026-08-23 — 選択肢 tap「MCP認証巡回」の直後に本物の Notion worker spec が貼られた; spec 優先を 1 行宣言して進めたのが正解だった
8. **The user says they picked an option by mistake** — reverse it immediately, even mid-execution, and drop that option from the candidate set. The retraction arrives at once, so progress is not a reason to keep it (this is item 7's "the later signal wins", with the user themselves as the source of the correction). Origin: 2026-09-04 — 「Notion は間違えて選択しました。Notion はないです」

**例（違反 / 改善後）:**

```
❌ 悪い例: 「以下の3点が問題です。[分析結果]。実装を進めます。」
✓ 良い例: 「以下の3点が問題です。[分析結果]。」 → AskUserQuestion("どの方針で進めますか？")

❌ 悪い例: 「調査結果をまとめました。[7項目のリスト]」
✓ 良い例: 「調査結果をまとめました。」 → AskUserQuestion("どれを採用しますか？", multiSelect)

❌ 悪い例: 「以下の選択肢があります。A: ... B: ... C: ... どれにしますか？」（散文形式のメニューを質問の体裁にしただけ — これも違反）
✓ 良い例: 同じ状況 → AskUserQuestion("どれにしますか？", options=["A: ...", "B: ...", "C: ..."])

❌ 悪い例（完了報告の締め）: 「…出荷完了です。hardening PR を今出しますか、それとも TODO.md に積みますか。」
✓ 良い例: 完了報告を書き切る → AskUserQuestion("hardening の扱いは？", options=["今 PR を出す", "TODO.md に積む"])

❌ 悪い例（検証手順メニュー）: 手順 1〜8 を列挙して「どれか走らせますか。」 — read-only の検証・probe は聞かずに同 turn で実行して結果ごと報告する。consent 質問は破壊的・高コスト・ユーザー実行必須の操作のみ
❌ 悪い例（merge 承認）: 「マージしてよければ実行します」 — merge 承認は git-commit.md「Merge Execution Default」どおり: plan 内なら質問なしで自己実行、plan 外は AskUserQuestion で 1 回取る
❌ 悪い例（選択肢の実行に手動 UI 操作が要る場合）: 「進め方は 2 択です: 1. /permissions で恒久許可 2. 再指示で単発リトライ」 — /permissions 追加・permission mode 切替・ブラウザ認証が必要でも、方針選択は AskUserQuestion で取り、選択後に手順を提示する。「どうせ手動操作が要る」は例外にならない
```

（再発 4 形の origin: 2026-06-23〜07-23 の 5 セッション — うち 3 件は prose-menu hook 追加後の再発で、全件が「？」でなく句点終端・条件付き宣言で hook をすり抜けた。hook 側 regex も同 PR で修正済み。）

**When NOT needed**: clear single path, all reversible. Steps inside an approved plan don't need individual confirmation.

**Expected tool/skill absent → don't silently substitute**: when a tool/skill the user asked for (or the task expects) is confirmed absent via `ToolSearch` — ToolSearch 0 件だけでは不在確定にならない: 断定前の triage（claude.ai scope 未注入 / 切断 / プラグイン 3 層）は `~/.claude/docs/claude-code-plugins.md` の Skill Availability Check — state the absence in one line and offer a fallback via AskUserQuestion (degraded alternative with its limits spelled out, or re-enable and do the real thing) — silent degraded substitution is the same violation as opaque substitution. If AskUserQuestion *itself* is absent, present numbered options at the end of a normal reply and stop (this fallback alone lifts the prose-menu ban) — never bundle undecided items into ExitPlanMode approval. **A user-typed tool name may be a typo — fuzzy-match before concluding absence**: an exact-name probe that returns nothing proves only that spelling is absent, so also try a 3-4 character prefix across the registries (`ls ~/.claude/skills ~/.claude/plugins/cache/*/ | grep -i '<prefix>'`, `compgen -c | grep -i '<prefix>'`) before asking what the user meant. Origin: 2026-07-27 — "fragment" (meant: `fractal`, an installed CLI + skill + plugin) probed as absent; a `grep -i frac` would have resolved it without a round-trip. Origin: 2026-06 sage — `open`-url substituted without consent; 5 decisions bundled into a plan approval → 2 rejects.

**Probe gates moved**: Verify-before-ask, Existing-facility probe, Capability claims and Negative search now live in the shared `~/.agents/AGENTS.md` (Probe Discipline section; imported by CLAUDE.md, so always loaded). The AskUserQuestion-specific consequence: a *value* (UDID, hostname, version, field name) is probed, not asked — AskUserQuestion is for *intent* ambiguity.

**Option label / description accuracy**: `grep`/`ls` to confirm the actual component identifier before writing AskUserQuestion option labels. **The probe gate covers the description body, not just the label** — a judgement word written there ("unused", "nobody uses it", "safe to delete", "zero loss", "no consumers", "unreachable") is subject to the Negative search and Capability claims clauses in the shared `~/.agents/AGENTS.md`. Putting an unconfirmed spec in an option with a "(needs measuring)" or "probably" hedge violates the hedge / deferral ban in the Japanese Output Discipline section of `~/.agents/AGENTS.md`; a read-only probe is not something to ask about, so run it in the same turn and then ask. Costs go in the description as **real numbers** (monthly figure, time delta, per-unit), and any comparison axis that would otherwise be added in a follow-up round (RAM, downtime, drift window) goes in the first ask. Origin: 2026-09-07 — a permission evaluation order was written into a description as "probably deny > ask > allow (needs measuring)" while the confirmed fact already sat in `rules/git-commit.md`; 2026-09-13 — "roughly 2× the price" led to two follow-up asks for the real numbers and a memory axis. **CLI flag names are values too** — before writing a CLI flag in an option label, run `<tool> [subcommand] help 2>&1 | grep -- <flag>` or `<tool> --help | grep -- <flag>` to confirm the flag exists with the exact spelling. Origin: 2026-05-10 mislabelled component (PR #310); 2026-05-11 mislabelled a flag the user's wording had right. **Executing-agent naming in labels**: when an option or its description says who runs a command, name the actor explicitly（「Claude が `gh pr merge` を実行」/「あなたが `!` で実行」）— never a bare first-person pronoun（「私」/ "I"）. The auto-mode classifier reads option labels verbatim and can attribute 「私」 to the USER, then deny the agent-executed path as a boundary violation. Origin: 2026-06-27 — 「私が merge（推奨）」の「私」をユーザーと誤読され、意図された agent merge が denial → `!` 再提示の round-trip。

**5+ issues**: group by user-goal theme (not file, not severity), make themes the options. Prevents post-question re-framing.

**選択肢の description には pros/cons・コスト・推奨根拠を整理して含め、推奨案の label に「(推奨)」を付ける**。Origin: 2026-07-03 orca session — ユーザー指示「質問の選択肢はpros/consが明確になるように情報を整理して提示して」（単発指示ベース）。
