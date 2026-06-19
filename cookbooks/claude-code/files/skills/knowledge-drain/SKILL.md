---
name: knowledge-drain
description: |
  ~/.claude/pending-cognify/*.md にたまった未取り込み knowledge を Cognee にドレインするループ skill。
  各ファイルを cognify → CHUNKS search で取り込みを確認 → 確認できたファイルのみ削除する。
  cognify timeout fallback で退避された保留ファイルを定期回収するための、Loop Engineering の知識配管ループ。
  デフォルトは dry-run（drain 対象の列挙のみ。cognify も削除もしない）。
  「knowledge drain」「pending-cognify をドレイン」「cognify 保留を回収」「drain knowledge backlog」でトリガー。
user-invocable: true
---

# knowledge-drain — Cognee 取り込み保留のドレインループ

## 目的

cognify timeout fallback（`~/.claude/docs/knowledge-persistence.md` の "Cognify Timeout Fallback"）は、
取り込めなかった知識を `~/.claude/pending-cognify/<date>-<slug>.md` に退避する。これらは手動で
再取り込みされるまで graph search に現れない。本ループはそのバックログを定期的に回収し、graph と
ファイルの乖離を閉じる。Loop Engineering の最小ループ（外部依存ゼロ・低リスク）として、
Cron → ローカル MCP → Cognee の配管検証も兼ねる。

## モード

- **dry-run（デフォルト）**: drain 対象を列挙するだけ。cognify も削除も一切しない。手動確認・配管検証用。
- **live**: 実際に cognify + 検証 + 削除まで行う。cron からは live で起動する。

起動プロンプトに "LIVE mode" の語が無ければ dry-run とみなす。

## 手順

### Step 0. 対象列挙（両モード共通）

`~/.claude/pending-cognify/*.md` を列挙する（`TODO.md` は除外）。
0 件なら `"knowledge-drain: no backlog — skipped"` と 1 行記録して **STOP**（graceful empty state）。

### Step 1. dry-run はここで終了

列挙したファイル名と各行数を報告して終了。drain は行わない。

### Step 2. ドレイン（live のみ）

各ファイル `f` について順に:

1. `f` の本文を cognify する（`mcp__cognee-local__cognify`、不可なら利用可能な connector の cognify）。
2. `cognify_status` を polling し、background 処理の完了を待つ。
3. `f` の本文から固有語を 2–3 個選び、`search_type: CHUNKS` で検索する。
4. **ヒットした** → `f` を削除し `"drained: <f>"` を記録。
   **空だった** → `f` を残し `"verify-failed: <f>"` を WARN で記録（次回再試行）。

### Step 3. TODO 整合（任意・live のみ）

`~/.claude/pending-cognify/TODO.md` に再取り込み TODO が残っていて、対応する `.md` が Step 2 で
drain 済みなら、その TODO エントリを削除する。

### Step 4. サマリ

`drained / verify-failed / skipped` の件数を報告する。

## 検証ゲート（最重要）

**削除は CHUNKS search のヒット後のみ。** ヒットしないファイルは絶対に削除しない。
cognify は MCP 経由で success を返しても background pipeline が無音失敗することがある
（knowledge-persistence の "Post-Cognify Verification"）。CHUNKS 検証がこの無音失敗の検出器であり、
取りこぼし（未取り込みのまま削除）を防ぐ唯一のゲート。

## ループ化（substrate: ローカル CronCreate）

プロトタイプ中は cron がこの skill を絶対パス参照する（deploy 不要）:

```
CronCreate(
  cron="7 9 * * 1-5",          # 平日朝（:00/:30 を避ける）
  durable=true,
  recurring=true,
  prompt="Follow the skill at ~/ManagedProjects/setup/cookbooks/claude-code/files/skills/knowledge-drain/SKILL.md in LIVE mode. Report drained/verify-failed/skipped counts."
)
```

注意: CronCreate の recurring は 7 日で自動失効する。恒久運用は検証後に home-lab 監視 LXC の
server cron（`claude -p` headless、auto-mitamae 同型）へ昇格する。検証後はこの skill を
`cookbooks/claude-code/default.rb` の skills リストに登録し mitamae deploy すれば `/knowledge-drain`
として起動できるようになる。
