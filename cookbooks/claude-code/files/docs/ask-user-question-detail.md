# AskUserQuestion — Examples & Origin Notes

Load when a `~/.claude/rules/ask-user-question.md` pointer matches the current task (writing an AskUserQuestion, handling a consent refusal, a contradicting late message, a missing tool, or option-label wording).

## pause-items-and-examples

**Item 2 (destructive operations)** origin: 2026-08-18 — an `ExitWorktree` refusal naming "1 commit will be discarded" was answered 0.3 seconds later with `discard_changes: true`, and the commit was destroyed.

**Item 7 (late contradicting information)** example declaration:「選択肢回答 X は貼付 spec で置き換えと解釈します」. Origin: 2026-08-23 — 選択肢 tap「MCP認証巡回」の直後に本物の Notion worker spec が貼られた; spec 優先を 1 行宣言して進めたのが正解だった。

**Item 8 (option picked by mistake)**: the retraction arrives at once, so progress is not a reason to keep it. Origin: 2026-09-04 — 「Notion は間違えて選択しました。Notion はないです」

Full ❌/✓ example block:

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

## expected-tool-absent

Silent degraded substitution is the same violation as opaque substitution. An exact-name probe that returns nothing proves only that spelling is absent, which is why the prefix search runs before asking what the user meant.

Origins: 2026-07-27 — "fragment" (meant: `fractal`, an installed CLI + skill + plugin) probed as absent; a `grep -i frac` would have resolved it without a round-trip. 2026-06 sage — `open`-url substituted without consent; 5 decisions bundled into a plan approval → 2 rejects.

## option-label-accuracy

Origins:

- 2026-09-07 — a permission evaluation order was written into a description as "probably deny > ask > allow (needs measuring)" while the confirmed fact already sat in `rules/git-commit.md`.
- 2026-09-13 — "roughly 2× the price" led to two follow-up asks for the real numbers and a memory axis.
- 2026-05-10 — mislabelled component (PR #310); 2026-05-11 — mislabelled a flag the user's wording had right.
- 2026-06-27 — 「私が merge（推奨）」の「私」をユーザーと誤読され、意図された agent merge が denial → `!` 再提示の round-trip。
- (推奨) labeling: 2026-07-03 orca session — ユーザー指示「質問の選択肢はpros/consが明確になるように情報を整理して提示して」（単発指示ベース）。
