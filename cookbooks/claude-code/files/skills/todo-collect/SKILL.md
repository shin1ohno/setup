---
name: todo-collect
description: |
  config（~/.claude/todo/sources.yaml + sources.local.yaml）に列挙された外部 capture
  ソース — Slack saved（後で見る）/ 📌 リアクション / self-DM、Google Tasks、
  Claude Code transcript の deferral 発話、カレンダー連携 Notion 議事録 — を sweep し、
  TODO 形に正規化（完了条件の起草 + provenance 付与）して機密性 routing どおりの
  memory store（ai-memory / memory-local）に tags:["todo"] で書き込む毎日ループ skill。
  explicit ソース（明示マーク）は自動保存 + 領収書 1 行、inferred ソース（推論抽出）は
  候補提案のみ（承認後に保存）。dedup は provenance キー。結果は ~/.claude/todo/ledger.md
  に追記。設計の真実源は ~/.claude/docs/todo-management.md。
  「todo collect」「TODO 集めて」「capture 集めて」「TODO 収集」でトリガー。
  注: ソース側の状態は絶対に変更しない（Task の完了化・saved 解除等をしない）。
  仕事ソースの sink は memory-local 固定 — 個人 ai-memory へ流すのは egress 違反。
user-invocable: true
---

# todo-collect

## 目的

2 相 capture（`~/.claude/docs/todo-management.md`）の第 2 相 = 正規化を担う。ユーザーは各ツールのネイティブ操作（self-DM に一言、📌 を付ける、Task を足す）で raw capture するだけ — この skill が非同期に完了条件を起草し、provenance を付け、正しい store へ入れる。3 点セットをユーザーが手で書くことはない。

## config

`~/.claude/todo/sources.yaml`（cookbook 管理、個人ソースのみ）+ `~/.claude/todo/sources.local.yaml`（非管理 — **work ソースはこちら**。公開 repo に置かない）。両方読み、`name` で union（local が同名を上書き）。schema は sources.yaml 冒頭コメント参照（name / class / adapter / query / sink / enabled）。

## 手順

### Step 0 — config 読込 + 到達性確認

enabled な各ソースの依存を確認: Slack 系 → Slack MCP ツール到達、google-tasks → `gws tasks tasklists list` が 200、sink → 対象 memory store の `memory_stats`。不達ソースは WARN + skip し、ledger に「未 sweep」と明記する（「0 件」と報告しない）。

### Step 1 — sweep（adapter 別）

**Slack 系共通（重要）**:

- **全ページ取得**: MCP 検索は 20 件/ページ上限で `cursor` を返す。`cursor` を `End of results` まで辿って全ページ取得する。1 ページで止めると保存件数が 20 を超える分を黙って取りこぼす（打ち切る場合は ledger に truncated 残数を明記 = silent cap 禁止）。
- **`after:` を saved / reaction に付けない**: 増分の担保は Step 2 の provenance dedup であって `after:` ではない。Slack の `after:` / `before:` は**元メッセージの投稿日**でフィルタするため、古いメッセージを後から saved / リアクションした分（Later の主用途そのもの）が全部弾かれる。Later は「現在の保存状態リスト」なので毎回フル sweep し、既出は dedup で落とす。
- **class は config の宣言に従う**（下の `（…）` は既定例。work-slack-saved は sources.local.yaml で inferred）。

- `slack-saved`: search `is:saved`（Later の In progress + Archived を返す）。full sweep（全ページ）
- `slack-reaction`: search `hasmy::<emoji>:`（query の emoji、既定 `pushpin`）。full sweep（全ページ）
- `slack-self-dm`: 自分の self-DM を search（`in:` 自 user、`channel_types=im`、from:自分）。self-DM は自分が今書くので後方 lookback は任意
- `google-tasks`（explicit）: `gws tasks tasks list --tasklist <id>` の needsAction のみ（query = tasklist 名）
- `transcript-deferral`（inferred）: `~/.claude/projects/*/*.jsonl` の直近 query 期間（既定 7d）から deferral 発話（「あとでやる」「後回し」「TODO にして」等）のうち領収書行（「→ … に保存」）が続かないものを抽出
- `calendar-notion-notes`（inferred）: `gws calendar` の直近イベント → 説明欄の Notion リンク → notion fetch → action item（自分宛て）抽出

### Step 2 — dedup

provenance キー（Slack permalink / task id / event id / transcript の session+行）で照合し、既出は skip。照合先: 対象 store の `browse(filters: {tags: "todo"})` の provenance 記載 + 前回 ledger。

### Step 3 — 正規化

各項目に 3 点セット（完了条件 / 対象 / 想定 class、個人タスクは完了条件 + 期日 or トリガー）を起草。本文に provenance（元リンク）を必ず含める。完了条件が起草できない項目は explicit でも inferred 扱いに降格（提案へ）。

### Step 4 — 書込 or 提案

- explicit → sink へ `remember(content, type='fact', tags=['todo'])` + 領収書 1 行（「→ memory-local に保存。完了条件: X」）
- inferred → dedup 済みの**全項目**を候補として提示（少数なら AskUserQuestion バッチ、多数なら ledger の候補セクションに全件列挙）、承認分のみ書込。**silent drop 禁止** — actionable でない（参照 / 期限切れ等）と判断した項目も黙って捨てず、候補に「除外候補（理由つき、既定 skip）」として残す。ユーザーが後で拾い直せる状態を保つ

### Step 5 — ledger 追記

`~/.claude/todo/ledger.md`（`mkdir -p ~/.claude/todo`）に: 実行日時 / ソース別 新規 N 件・候補 M 件（除外候補も理由つきで列挙）・dedup skip 数 / ページ打ち切りがあれば truncated 残数 / 不達ソースの WARN。

## 検証ゲート（最重要）

- ソース側の状態を変更しない — Google Task を complete にしない、saved を解除しない、リアクションを消さない
- **sink 越境禁止**: work 系 adapter（Mercari Slack 等）の sink が `ai-memory` になっていたら書き込まずに停止して警告（egress 違反）
- **Slack sweep は全ページ取得を確認**: `End of results` まで辿ったか（1 ページ=20 件ちょうどで止まっていないか）。saved / reaction に `after:` を付けていないか（付けると投稿日フィルタで古い保存分が全部消える）。打ち切る場合は ledger に truncated 残数を明記（silent cap 禁止）
- inferred 項目は承認なしに書き込まない。actionable でないと判断した分も silent drop せず候補に理由つきで残す
- 書込後、`browse` で着地を確認してから領収書を出す（Verify-before-done）

## ループ化

毎日 1 回、その日最初の対話セッション冒頭で起動（`/morning-triage` と対で回すのが自然）。headless 自動化は Slack connector が headless で使えない制約により、`gws` / `gh` 系ソースのみ先行可。`/todo-reconcile`（週 1 の出口 = 棚卸し）とは独立 — collect は「入口」。
