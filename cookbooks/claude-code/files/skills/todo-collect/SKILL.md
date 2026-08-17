---
name: todo-collect
description: |
  config（~/.claude/todo/sources.yaml + sources.local.yaml）に列挙された外部 capture
  ソース — Slack saved（後で見る）/ 📌 リアクション / self-DM、Google Tasks、
  Apple Reminders（remind --dump）、Claude Code transcript の deferral 発話、
  カレンダー連携 Notion 議事録 — を sweep し、
  TODO 形に正規化（完了条件の起草 + provenance 付与）して機密性 routing どおりの
  memory store（ai-memory / memory-work）に tags:["todo"] で書き込む毎日ループ skill。
  explicit ソース（明示マーク）は自動保存 + 領収書 1 行、inferred ソース（推論抽出）は
  候補提案のみ（承認後に保存）。dedup は provenance キー。結果は ~/.claude/todo/ledger.md
  に追記。設計の真実源は ~/.claude/docs/todo-management.md。
  「todo collect」「TODO 集めて」「capture 集めて」「TODO 収集」でトリガー。
  注: ソース側の状態は絶対に変更しない（Task の完了化・saved 解除等をしない）。
  例外は連携ストアの Apple Reminders のみ（リンクトークン annotate と close 伝播 complete）。
  仕事ソースの sink は memory-work 固定 — 個人 ai-memory へ流すのは egress 違反。
user-invocable: true
---

# todo-collect

## 目的

2 相 capture（`~/.claude/docs/todo-management.md`）の第 2 相 = 正規化を担う。ユーザーは各ツールのネイティブ操作（self-DM に一言、📌 を付ける、Task を足す）で raw capture するだけ — この skill が非同期に完了条件を起草し、provenance を付け、正しい store へ入れる。3 点セットをユーザーが手で書くことはない。

## config

`~/.claude/todo/sources.yaml`（cookbook 管理、個人ソースのみ）+ `~/.claude/todo/sources.local.yaml`（非管理 — **work ソースはこちら**。公開 repo に置かない）。両方読み、`name` で union（local が同名を上書き）。schema は sources.yaml 冒頭コメント参照（name / class / adapter / query / sink / enabled）。

## 手順

### Step 0 — config 読込 + 到達性確認

enabled な各ソースの依存を確認: Slack 系 → Slack MCP ツール到達、google-tasks → `gws tasks tasklists list` が 200、sink → 対象 memory store の `memory_stats`。不達ソースは WARN + skip し、ledger に「未 sweep」と明記する（「0 件」と報告しない）。**gws の偽ゼロ注意**: gws はエラー時も JSON（`{"error":{...}}`）を stdout に返すため、`2>/dev/null` + `jq '[.items[]?]'` はエラーを 0 件に化けさせる。sweep 結果が 0 件のときは stderr を出して再実行し、401 `invalid_rapt`（Google 再認証切れ）なら `! gws auth login` を提示して「未 sweep」扱い。probe が通っても数分後の data call でトークン失効し得る — 0 件の positive control を必ず取る。

### Step 1 — sweep（adapter 別）

**Slack 系共通（重要）**:

- **全ページ取得**: MCP 検索は 20 件/ページ上限で `cursor` を返す。`cursor` を `End of results` まで辿って全ページ取得する。1 ページで止めると保存件数が 20 を超える分を黙って取りこぼす（打ち切る場合は ledger に truncated 残数を明記 = silent cap 禁止）。
- **`after:` を saved / reaction に付けない**: 増分の担保は Step 2 の provenance dedup であって `after:` ではない。Slack の `after:` / `before:` は**元メッセージの投稿日**でフィルタするため、古いメッセージを後から saved / リアクションした分（Later の主用途そのもの）が全部弾かれる。Later は「現在の保存状態リスト」なので毎回フル sweep し、既出は dedup で落とす。
- **class は config の宣言に従う**（下の `（…）` は既定例。work-slack-saved は sources.local.yaml で inferred）。

- `slack-saved`: search `is:saved`（Later の In progress + Archived を返す）。full sweep（全ページ）
- `slack-reaction`: search `hasmy::<emoji>:`（query の emoji、既定 `pushpin`）。full sweep（全ページ）
- `slack-self-dm`: 自分の self-DM を search（`in:` 自 user、`channel_types=im`、from:自分）。self-DM は自分が今書くので後方 lookback は任意
- `google-tasks`（explicit）: `gws tasks tasks list --params '{"tasklist":"<id>"}'` の needsAction のみ（query = tasklist 名）。gws はサブコマンド固有フラグを持たず**引数は全て `--params` JSON 渡し**（`--tasklist` 等は unexpected argument で落ちる）
- `apple-reminders`（explicit）: capture lists（= config の apple-reminders ソースの query リスト群 + `mirror.list`）ごとに `remind --dump --list <名前>` を実行。未完了・notes に `[ai-todo:…]` トークン無し・どの open memory todo からも `reminders:<externalId>` で未参照・due が capture horizon 内（既定 14 日、`capture.due_horizon_days` で変更・負値で無効 — 先の予定 reminder は Reminders 自身が通知を担うので取り込まない）、の 4 条件を満たすものが candidate（Step 6 の remind_sync.rb が返す `capture_candidates` と同一規則）。explicit class なので自動 remember + provenance `reminders:<externalId>`。**sink は既定値** — Inbox は個人/work 混在ソースなので候補ごとに内容で routing する（work 形 → memory-work。todo-management.md の capture routing と同一）
- `transcript-deferral`（inferred）: `~/.claude/projects/*/*.jsonl` の直近 query 期間（既定 7d）から deferral 発話（「あとでやる」「後回し」「TODO にして」等）のうち領収書行（「→ … に保存」）が続かないものを抽出
- `calendar-notion-notes`（inferred）: `gws calendar` の直近イベント → 説明欄の Notion リンク → notion fetch → action item（自分宛て）抽出

### Step 2 — dedup

provenance キー（Slack permalink / task id / event id / transcript の session+行）で照合し、既出は skip。照合先: 対象 store の `browse(filters: {tags: "todo"})` の provenance 記載 + 前回 ledger。

### Step 3 — 正規化

各項目に 3 点セット（完了条件 / 対象 / 想定 class、個人タスクは完了条件 + 期日 or トリガー）を起草。本文に provenance（元リンク）を必ず含める。完了条件が起草できない項目は explicit でも inferred 扱いに降格（提案へ）。

### Step 4 — 書込 or 提案

- explicit → sink へ `remember(content, type='fact', tags=['todo'])` + 領収書 1 行（「→ memory-work に保存。完了条件: X」）
- inferred → dedup 済みの**全項目**を候補として提示（少数なら AskUserQuestion バッチ、多数なら ledger の候補セクションに全件列挙）、承認分のみ書込。**silent drop 禁止** — actionable でない（参照 / 期限切れ等）と判断した項目も黙って捨てず、候補に「除外候補（理由つき、既定 skip）」として残す。ユーザーが後で拾い直せる状態を保つ

### Step 5 — ledger 追記

`~/.claude/todo/ledger.md`（`mkdir -p ~/.claude/todo`）に: 実行日時 / ソース別 新規 N 件・候補 M 件（除外候補も理由つきで列挙）・dedup skip 数 / ページ打ち切りがあれば truncated 残数 / 不達ソースの WARN。

### Step 6 — Reminders mirror 同期（remind_sync.rb）

Apple Reminders を open memory todo の surface（mirror）として同期する（設計と sync 5 規則: `~/.claude/docs/todo-management.md` の「Apple Reminders integration」）。実装は同 skill ディレクトリの `remind_sync.rb` — 状態ファイルを持たず、毎回 2 つのダンプから plan を導出する（リンクは reminder notes 末尾の `[ai-todo:<memory-id>]` トークンと memory content 内の `reminders:<externalId>` provenance のみ）。

1. **memory dump 作成**: 両 store の `browse(filters: {tags: "todo"})` 結果（open のみ）を `[{"id","store","content","tags"}]` の JSON に整形して MEM.json へ
2. **config 作成**: sources.yaml + sources.local.yaml の merge 結果から `{"mirror":{...},"capture":{"lists":[...],"sink":"..."}}` を CONFIG.json へ（capture.lists = apple-reminders ソースの query リスト群）
3. **1 回目 apply**: `ruby remind_sync.rb --config CONFIG.json --memory-dump MEM.json --apply`。reminder_actions（mklist→add→annotate→complete）は script 自身が remind CLI で実行する。stdout JSON のうち skill が MCP で実行するのは: `memory_actions`（forget — reminder 完了を機械的証拠として対応 store の todo を閉じる）と `capture_candidates`（Step 2-4 の dedup→正規化→書込フローに乗せる。explicit なので自動 remember + 領収書）
4. **2 回目 apply**: 同コマンドを再実行 — capture で新規 remember した分への annotate（notes に `[ai-todo:<id>]` 追記）が走って収束する
5. **冪等確認**: 3 回目（`--apply` 無しの plan）で `counts` が全規則 0 件であることを確認。0 でなければ収束失敗 — それ以上書き込まず ledger に WARN

件数（add / annotate / complete / forget / capture 候補）と収束確認の結果は Step 5 の ledger に追記する。

## 検証ゲート（最重要）

- ソース側の状態を変更しない — Google Task を complete にしない、saved を解除しない、リアクションを消さない
- **Reminders は連携ストア — 非連携 capture ソース（Slack / Google Tasks 等）の不変更原則の例外**: Apple Reminders に限り、リンクトークンの annotate（notes への `[ai-todo:<id>]` 追記）と close 伝播の complete の 2 操作のみ変更可。それ以外（reminder の削除・タイトル編集・リスト移動・トークン以外の notes 書換え）は禁止
- **sink 越境禁止**: work 系 adapter（Mercari Slack 等）の sink が `ai-memory` になっていたら書き込まずに停止して警告（egress 違反）
- **Slack sweep は全ページ取得を確認**: `End of results` まで辿ったか（1 ページ=20 件ちょうどで止まっていないか）。saved / reaction に `after:` を付けていないか（付けると投稿日フィルタで古い保存分が全部消える）。打ち切る場合は ledger に truncated 残数を明記（silent cap 禁止）
- inferred 項目は承認なしに書き込まない。actionable でないと判断した分も silent drop せず候補に理由つきで残す
- 書込後、`browse` で着地を確認してから領収書を出す（Verify-before-done）

## ループ化

毎日 1 回、その日最初の対話セッション冒頭で起動（`/morning-triage` と対で回すのが自然）。headless 自動化は Slack connector が headless で使えない制約により、`gws` / `gh` 系ソースのみ先行可。`/todo-reconcile`（週 1 の出口 = 棚卸し）とは独立 — collect は「入口」。
