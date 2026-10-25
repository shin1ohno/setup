# Critical Rules — AskUserQuestion

- **Every ambiguity**: use AskUserQuestion, never guess
- **Analysis is NOT a proposal**: end findings with AskUserQuestion asking direction

**Pause** and confirm:
1. Ambiguous requirements ("improve this", "clean this up")
2. Before destructive operations (delete, reset, drop, force-push). **A tool's own refusal text that says "Confirm with the user, then re-invoke with `<flag>: true`" IS the consent gate** — do not satisfy it with your own judgement in the same turn. When the thing to be discarded is a commit or uncommitted work, take one AskUserQuestion even inside an approved plan.
3. Scope decisions (no unilateral expansion)
4. Technical choices with no known preference
5. Uncertain assumptions ("this is probably right")
6. User's stated direction conflicts with an existing `rules/*.md` rule — don't silently follow the rule; surface the conflict ("rule X requires A but your direction is B — revise the rule or make an exception?"), and when a design change lands, sync the rule file in the same turn
7. **回答確定直後に届いた新情報が回答の前提と矛盾する場合**（mid-turn の spec paste・訂正メッセージ・遅れて届いた添付）— 黙って blend しない。どちらを正としたかを 1 行で明示して進める（後から届いた・より具体的な信号が通常は正）。両立し得て判断がつかない場合のみ再度 AskUserQuestion。
8. **The user says they picked an option by mistake** — reverse it immediately, even mid-execution, and drop that option from the candidate set; progress is not a reason to keep it (item 7's "the later signal wins", with the user as the source).

**例（違反 → 改善後）:**

- 分析結果のあと「実装を進めます」→ 分析で止め AskUserQuestion("どの方針で進めますか？")
- 「調査結果をまとめました。[7項目]」で終わる → AskUserQuestion("どれを採用しますか？", multiSelect)
- 散文メニュー「A / B / C どれにしますか？」（質問の体裁でも違反）→ AskUserQuestion(options=["A","B","C"])
- 完了報告の締めに「hardening PR を今出しますか、TODO.md に積みますか。」→ 報告を書き切ってから AskUserQuestion(options)
- 検証手順 1〜8 を並べて「どれか走らせますか。」→ read-only の検証・probe は聞かずに同 turn で実行して結果ごと報告。consent 質問は破壊的・高コスト・ユーザー実行必須の操作のみ
- 「マージしてよければ実行します」→ git-commit.md「Merge Execution Default」どおり: plan 内なら質問なしで自己実行、plan 外は AskUserQuestion で 1 回取る
- 選択肢の実行に手動 UI 操作（/permissions 追加・permission mode 切替・ブラウザ認証）が要る場合の散文 2 択 → 方針選択は AskUserQuestion で取り、選択後に手順を提示。「どうせ手動操作が要る」は例外にならない

Detail: see `~/.claude/docs/ask-user-question-detail.md#pause-items-and-examples`.

**When NOT needed**: clear single path, all reversible. Steps inside an approved plan don't need individual confirmation.

**Expected tool/skill absent → don't silently substitute**: once `ToolSearch` confirms a requested/expected tool or skill is absent (0 件だけでは不在確定にならない — triage via `~/.claude/docs/claude-code-plugins.md` Skill Availability Check), state the absence in one line and offer a fallback via AskUserQuestion (degraded alternative with its limits spelled out, or re-enable and do the real thing); silent degraded substitution is a violation. If AskUserQuestion *itself* is absent, present numbered options at the end of a normal reply and stop (this fallback alone lifts the prose-menu ban) — never bundle undecided items into ExitPlanMode approval. **A user-typed tool name may be a typo**: before concluding absence, also try a 3-4 character prefix (`ls ~/.claude/skills ~/.claude/plugins/cache/*/ | grep -i '<prefix>'`, `compgen -c | grep -i '<prefix>'`).

Detail: see `~/.claude/docs/ask-user-question-detail.md#expected-tool-absent`.

**Probe gates moved**: Verify-before-ask, Existing-facility probe, Capability claims and Negative search live in `~/.agents/AGENTS.md` (Probe Discipline, always loaded). Consequence here: a *value* (UDID, hostname, version, field name) is probed, not asked — AskUserQuestion is for *intent* ambiguity.

**Option label / description accuracy**: `grep`/`ls` the actual component identifier before writing labels. **The probe gate covers the description body too** — judgement words ("unused", "safe to delete", "zero loss", "no consumers", "unreachable") fall under AGENTS.md Negative search / Capability claims. An unconfirmed spec with a "(needs measuring)" / "probably" hedge violates the hedge / deferral ban: run the read-only probe in the same turn, then ask. Costs go in as **real numbers** (monthly figure, time delta, per-unit), and any comparison axis a follow-up would add (RAM, downtime, drift window) goes in the first ask. **CLI flag names are values too** — confirm with `<tool> [subcommand] help 2>&1 | grep -- <flag>` or `<tool> --help | grep -- <flag>`. **Executing-agent naming in labels**: name who runs a command（「Claude が `gh pr merge` を実行」/「あなたが `!` で実行」）, never a bare 「私」/ "I" — the auto-mode classifier reads labels verbatim and can attribute 「私」 to the USER, then deny the agent-executed path.

Detail: see `~/.claude/docs/ask-user-question-detail.md#option-label-accuracy`.

**5+ issues**: group by user-goal theme (not file, not severity), make themes the options. Prevents post-question re-framing.

**選択肢の description には pros/cons・コスト・推奨根拠を整理して含め、推奨案の label に「(推奨)」を付ける**。
