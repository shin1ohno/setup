# Critical Rules — AskUserQuestion

- **Every ambiguity**: use AskUserQuestion, never guess
- **Analysis is NOT a proposal**: end findings with AskUserQuestion asking direction

**Pause** and confirm:
1. Ambiguous requirements ("improve this", "clean this up")
2. Before destructive operations (delete, reset, drop, force-push)
3. Scope decisions (no unilateral expansion)
4. Technical choices with no known preference
5. Uncertain assumptions ("this is probably right")
6. User's stated direction conflicts with an existing `rules/*.md` rule — don't silently follow the rule; surface the conflict ("rule X requires A but your direction is B — revise the rule or make an exception?"), and when a design change lands, sync the rule file in the same turn

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

**Verify-before-ask gate**: before AskUserQuestion-ing for a *value* (UDID, hostname, version, JSON field, env var), probe instead — `ssh`, `grep`, `curl`, `xcrun`, `gh api`, `git log`, `ls`, `git rev-parse`. AskUserQuestion is for *intent* ambiguity, not missing facts. Origin: 2026-04-28 weave session asked for iPad UDID that `xcrun devicectl list devices` returned.

**Existing-facility probe before asking or building**: before asking where keys/backups/credentials live, or before writing a NEW backup/restore/keepalive/wrapper mechanism, `rg -i '<keyword>' ~/ManagedProjects/setup/cookbooks/ ~/ManagedProjects/setup/bin/ ~/ManagedProjects/setup/docs/` — the managing cookbook's source names the storage location and its config knobs (the secrets classifier blocks reading key *material*, not filename greps; absolute paths so it works from any cwd). To work around OS behavior (sudo-prompt timing etc.), tune the config knob of the cookbook that already owns the feature (e.g. mac-sudo `timestamp_timeout=N`) — config-at-source beats a new runtime layer. Origin: 2026-05-18 GPG import re-implementation proposed while `cookbooks/gpg-backup` existed; 2026-06-15 `bin/apply` keepalive created then deleted the next PR in favor of `timestamp_timeout`.

**Capability claims are values too**: probe before asserting "can X support Y?". Use `mise registry`, `brew info`, `<tool> --help | grep`, `pip index versions / npm view / cargo search`, `curl -fsI`. Recall-from-training is not evidence. Origin: 2026-05-04 "yes mise pipx" claim hit 2 blockers, ~30 min pivot. **Side-effect probe for NEW CLI commands**: before designing flow around the output / cache / state mutation of a CLI command you haven't directly observed, run it once and `find <likely-paths> -newer /tmp/sentinel -type f` (or `strace -e trace=openat,write`) to confirm where it writes. Origin: 2026-05-11 `aws login --remote` cache location unfindable → PR #339+#340 reverted. **Structured response fields are probes too**: when a fetched JSON/API response already contains a boolean field answering the capability question (e.g. `guestsCanModify`, `permissions.canEdit`, `editable`, `can_*`), read it before asserting the limit — the probe already happened; not reading it is the same failure as not probing at all. Origin: 2026-06-28 Calendar — asserted "only the organizer can reschedule" twice while `guestsCanModify=true` was already in the fetched event JSON; built an unnecessary hold-workaround + draft detour the user caught and reversed. **社内サービス・業務システムの「対応済み/未対応・可能/不可・未計測」も capability claim** — probe はドキュメントではなく該当リポのコード読解（手元に無ければ `~/ManagedProjects/` に clone、sparse-checkout 可）＋ Slack/Notion/code search。結論には file:line を添える。Notion/Slack/Jira/PR タイトルは経緯の証拠であって実装状況の証拠ではない（実装は文書より先に動く）。Origin: 2026-06 zp-SHIN — 対応状況を文書から断定し、ユーザーがコード読解を明示要求。**「決定済み/導入決定/一次判定の所管」などの決議状況クレームも同様** — probe 先は決定記録ブロック（Design Doc の Status・決定事項欄・決議ログ）であり、コード読解では決議は判定できない。提案節・DRAFT 由来の内容は「提案（未決議）」とタグ付けして書く。Origin: 2026-07-06 / 07-22 — CRM 一次判定・割引送料を決定済みと誤提示、crit 指摘で全 Design Doc が Status=DRAFT と判明。**決議済みでも「有効範囲」は別に読む** — 決定記録を引用するときは適用範囲（対象フェーズ・期限・前提条件）まで読み、恒久方針として書けるのは記録自身がそう書いている場合のみ。「このフェーズでは適用しない」は「将来も適用しない」ではない。範囲が読み取れない決定は「フェーズ限定（範囲未確認）」とタグ付けする。Origin: 2026-07-29 — フェーズ限定の非適用決定を将来にわたる決定として分析ドキュメントに書き、ユーザー指摘（「そのフェーズでは適用しないという意思決定の記録を将来にわたる決定と読み違えたのでは」）で訂正。

**Negative search is not evidence of absence — 完全性主張も同じ**: 「参照ゼロ / 存在しない / 未対応」だけでなく「N 件確定 / 全部で N 箇所 / 掃除済み」と断定する前にも、(a) positive control — 同じ検索コマンドが既知トークンで非ゼロを返すことを確認する（rg 不在・sandbox 遮断・パス誤り・zsh エラーは真の 0 件と出力上区別できない）、(b) `git grep` / `git ls-files` でクロスチェック、(c) 探索でも先頭 `cd` 禁止（chpwd フックの stdout 汚染が偽陰性を生む — `git-commit.md` の git 版ルールの一般化）— 絶対パス引数で。非ゼロだが不完全な結果は 0 件より危険（「N 件」を数字付きで報告してしまう）— 検索対象が複数の表記形を持つ場合は不変トークンだけで引いて分類する。テンプレート機構の漏れ・GitHub 検索の hyphen 分割・兄弟リポ probe・短オプション結合形と flag parse 失敗の各論: Detail: see `~/.claude/docs/negative-search-detail.md`。Origin: 2026-06-27〜07-03 に 3 プロジェクトで 3 件（「sage 参照ゼロ」直後に servers.yml で発見 / #45 が `--search` 不一致 / cd の tree フック + 浅い find で cookbook 見落とし）; 2026-08-02 setup で 8 件と報告した pipefail サイトが実は 9 件（`-o pipefail` が `set -euo pipefail` の部分文字列にならず、`-uo` 変種も漏れた）、同セッションで `rg --glob` / `ugrep --include` が flag parse に失敗して既知ヒットを欠いた結果を無言で返した。

**Option label accuracy**: `grep`/`ls` to confirm the actual component identifier before writing AskUserQuestion option labels. **CLI flag names are values too** — before writing a CLI flag in an option label, run `<tool> [subcommand] help 2>&1 | grep -- <flag>` or `<tool> --help | grep -- <flag>` to confirm the flag exists with the exact spelling. Origin: 2026-05-10 mislabelled component (PR #310); 2026-05-11 mislabelled a flag the user's wording had right. **Executing-agent naming in labels**: when an option or its description says who runs a command, name the actor explicitly（「Claude が `gh pr merge` を実行」/「あなたが `!` で実行」）— never a bare first-person pronoun（「私」/ "I"）. The auto-mode classifier reads option labels verbatim and can attribute 「私」 to the USER, then deny the agent-executed path as a boundary violation. Origin: 2026-06-27 — 「私が merge（推奨）」の「私」をユーザーと誤読され、意図された agent merge が denial → `!` 再提示の round-trip。

**5+ issues**: group by user-goal theme (not file, not severity), make themes the options. Prevents post-question re-framing.

**選択肢の description には pros/cons・コスト・推奨根拠を整理して含め、推奨案の label に「(推奨)」を付ける**。Origin: 2026-07-03 orca session — ユーザー指示「質問の選択肢はpros/consが明確になるように情報を整理して提示して」（単発指示ベース）。
