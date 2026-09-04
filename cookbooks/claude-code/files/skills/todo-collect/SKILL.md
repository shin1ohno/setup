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
  候補として ~/.claude/todo/candidates.jsonl（O(open) の承認待ちキュー、python3 helper
  todo_queue.py が再生成）に残す。dedup は正規 provenance key。run 記録は
  ~/.claude/todo/runs/<RUN_TS>-collect.md（1 run 1 file）。設計の真実源は
  ~/.claude/docs/todo-management.md。
  「todo collect」「TODO 集めて」「capture 集めて」「TODO 収集」でトリガー。
  注: ソース側の状態は絶対に変更しない（Task の完了化・saved 解除等をしない）。
  例外は連携ストアの Apple Reminders のみ（リンクトークン annotate と close 伝播 complete）。
  仕事ソースの sink は memory-work 固定 — 個人 ai-memory へ流すのは egress 違反。
user-invocable: true
---

# todo-collect

## 目的

2 相 capture（`~/.claude/docs/todo-management.md`）の第 2 相 = 正規化を担う。ユーザーは各ツールのネイティブ操作（self-DM に一言、📌 を付ける、Task を足す）で raw capture するだけ — この skill が非同期に完了条件を起草し、provenance を付け、正しい store へ入れる。3 点セットをユーザーが手で書くことはない。承認待ちの inferred 候補は `candidates.jsonl` に構造化して残し、`/todo-approve`（対話）か承認面（config の `surfaces`）で処置される。

## config

`~/.claude/todo/sources.yaml`（cookbook 管理、個人ソースのみ）+ `~/.claude/todo/sources.local.yaml`（非管理 — **work ソースはこちら**。公開 repo に置かない）。両方読み、`name` で union（local が同名を上書き。top-level の `queue:` / `mirror:` / `surfaces:` は local があれば丸ごと置換）。schema は sources.yaml 冒頭コメント参照（name / class / adapter / query / sink / enabled / `max_age_days`）。マージ結果を `~/.claude/todo/tmp/<RUN_TS>-config.json` に JSON で書く — helper は YAML を読めない（stdlib のみ）。

## ファイルと helper

- helper: `python3 ~/.claude/skills/todo-collect/todo_queue.py`（`init` / `validate` / `filter` / `summary`。ruby ではなく python3 — headless runner の PATH で解決するのが python3 だけ）
- `~/.claude/todo/candidates.jsonl`: 承認待ちキュー（1 行目 meta、以降 1 候補 1 行、O(open)）。**Write / Edit ツールで直接書かない** — 書くのは helper の `filter` だけ
- `~/.claude/todo/runs/<RUN_TS>-collect.md`: この run の記録（write-once、1 run 1 file）。他 run のファイルは読まない
- `~/.claude/todo/ledger.md`: 1 行/run の index。runner（無人 run）が書く。対話 run では書かれない（`summary` は `runs/` から履歴を導く）
- `~/.claude/todo/tmp/<RUN_TS>-sweep.json`: sweep 結果の構造化ハンドオフ（下記 Step 3b）
- RUN_TS は runner から渡される。対話実行では `$(date -u +%Y-%m-%dT%H:%M:%SZ)-$$` を自分で作る

## 手順

### Step 0 — init + config 読込 + 到達性確認

まず `python3 ~/.claude/skills/todo-collect/todo_queue.py init` を毎回呼ぶ（冪等: `runs/` `tmp/` の作成、旧 `ledger.md` があれば `runs/0000-legacy-ledger-…` へ 1 回だけ移動、index 3 行と meta のみの `candidates.jsonl` を生成）。

enabled な各ソースの依存を確認: Slack 系 → Slack MCP ツール到達、google-tasks → `gws tasks tasklists list` が 200、sink → 対象 memory store の `memory_stats`。不達ソースは WARN + skip し、sweep.json の `sources[]` に `status: unswept` + `reason` で、run log にも「未 sweep」と明記する（「0 件」と報告しない）。**gws の偽ゼロ注意**: gws はエラー時も JSON（`{"error":{...}}`）を stdout に返すため、`2>/dev/null` + `jq '[.items[]?]'` はエラーを 0 件に化けさせる。sweep 結果が 0 件のときは stderr を出して再実行し、401 `invalid_rapt`（Google 再認証切れ）なら `! gws auth login` を提示して `unswept` 扱い。probe が通っても数分後の data call でトークン失効し得る — 0 件の positive control を必ず取る。

### Step 1 — sweep（adapter 別）

**Slack 系共通（重要）**:

- **全ページ取得**: MCP 検索は 20 件/ページ上限で `cursor` を返す。`cursor` を `End of results` まで辿って全ページ取得する。1 ページで止めると保存件数が 20 を超える分を黙って取りこぼす（打ち切る場合は `status: truncated` + `remaining`（不明なら `"unknown"`）= silent cap 禁止）。
- **`after:` を saved / reaction に付けない**: 増分の担保は Step 2 の dedup であって `after:` ではない。Slack の `after:` / `before:` は**元メッセージの投稿日**でフィルタするため、古いメッセージを後から saved / リアクションした分（Later の主用途そのもの）が全部弾かれる。Later は「現在の保存状態リスト」なので毎回フル sweep し、既出は dedup で落とす。
- **class は config の宣言に従う**（下の `（…）` は既定例。work-slack-saved は sources.local.yaml で inferred）。

- `slack-saved`: search `is:saved`（Later の In progress + Archived を返す）。full sweep（全ページ）
- `slack-reaction`: search `hasmy::<emoji>:`（query の emoji、既定 `pushpin`）。full sweep（全ページ）
- `slack-self-dm`: 自分の self-DM を search（`in:` 自 user、`channel_types=im`、from:自分）。self-DM は自分が今書くので後方 lookback は任意。**`[todo-loop]` で始まるメッセージは除外**（headless ループが自分の実行結果や候補 DM を self-DM に投げるので、capture ではなくこのパイプライン自身の通知）
- `google-tasks`（explicit）: `gws tasks tasks list --params '{"tasklist":"<id>"}'` の needsAction のみ（query = tasklist 名）。gws はサブコマンド固有フラグを持たず**引数は全て `--params` JSON 渡し**（`--tasklist` 等は unexpected argument で落ちる）
- `apple-reminders`（explicit）: capture lists（= config の apple-reminders ソースの query リスト群 + `mirror.list`）ごとに `remind --dump --list <名前>` を実行。未完了・notes に `[ai-todo:…]` トークン無し・どの open memory todo からも `reminders:<externalId>` で未参照・due が capture horizon 内（既定 14 日、`capture.due_horizon_days` で変更・負値で無効 — 先の予定 reminder は Reminders 自身が通知を担うので取り込まない）、の 4 条件を満たすものが candidate（Step 6 の remind_sync.rb が返す `capture_candidates` と同一規則）。explicit class なので自動 remember + provenance `reminders:<externalId>`。**sink は既定値** — Inbox は個人/work 混在ソースなので候補ごとに内容で routing する（work 形 → memory-work。todo-management.md の capture routing と同一）
- `transcript-deferral`（inferred）: `~/.claude/projects/*/*.jsonl` の直近 query 期間（既定 7d）から deferral 発話（「あとでやる」「後回し」「TODO にして」等）のうち領収書行（「→ … に保存」）が続かないものを抽出
- `calendar-notion-notes`（inferred）: `gws calendar` の直近イベント → 説明欄の Notion リンク → notion fetch → action item（自分宛て）抽出

### Step 2 — dedup + disposition 照合（材料の取得）

照合先は 2 つ。どちらも `limit:500` を明示し、応答の `total` / `truncated` を返却件数と突き合わせて **3 値**（`complete` / `truncated` + `remaining` / `unreached` + `reason`）を記録する:

1. `browse(filters: {tags: "todo"}, limit: 500)` — 既存 todo。本文の `key=<key>` 行が dedup の照合キー
2. `browse(filters: {tags: "todo-disposition"}, limit: 500)` — 採否台帳（reject / snooze / never / done / expired / revive、append-only、latest-wins）

適用（既存 key の除外、却下済み・snooze 中・done 済みの非表示、aging）は **helper の `filter` が決定的に行う**。「前回の記録を見て省略」という prose の判断はしない。

**`truncated` の扱い**: todos 側が truncated なら explicit の新規保存を保留し（既に捕獲済みの TODO を新規と誤認して二重に作るのを防ぐ）、dispositions 側が truncated / unreached なら helper は disposition フィルタを適用せず全件を候補に出す（隠す方向の誤りを出さない）。どちらも run log に `truncated 残数` を書く。

### Step 3 — 正規化

各項目に 3 点セット（完了条件 / 対象 / 想定 class、個人タスクは完了条件 + 期日 or トリガー）を起草。provenance は**正規 key** に正規化する: Slack `slack:<channel_id>/<ts>`（permalink の `p<digits>` から。ホスト名は使わない — `mercari.slack.com` / `mercari.enterprise.slack.com` は同一 key）、Notion `notion:<page_id>#<idx|block>`、transcript `transcript:<session_id>:<line>`、Reminders `reminders:<externalId>`、Google Tasks `gtasks:<list>/<task>`。todo レコードも disposition レコードも**本文 1 行目に `key=<key>`** を書く。完了条件が起草できない項目は explicit でも inferred 扱いに降格（候補へ）。

### Step 3b — sweep.json を書く

`~/.claude/todo/tmp/<RUN_TS>-sweep.json` に `{"run", "sources": [{name, class, status, count, remaining, reason}], "todos": <envelope>, "dispositions": <envelope>, "items": [...]}` を書く。`items[]` は inferred の**全件**（actionable かどうかを自分で判断して落とさない — aging と disposition は helper が構造で判断する）: `{source, class, title, permalink または key, thread_key?, origin_ts, due, draft_close_condition, confidence, idx?}`。`origin_ts` は元メッセージ・会議の日時（aging の基準）。envelope は Step 2 の `{"enum": {state,total,returned,remaining,reason}, "records": [...]}`。`python3 … validate --sweep <path> --run <RUN_TS>` が exit 0 になるまで直す。

### Step 4 — 書込 / filter

- explicit → dedup（正規 key が todos.records の `key=` 行に無い）→ sink へ `remember(content, type='fact', tags=['todo','<source>','via:collect'])` + 領収書 1 行（「→ memory-work に保存。完了条件: X」）
- inferred → `python3 … filter --sweep <sweep> --run <RUN_TS> --config <config.json> --run-log <run log>` で `candidates.jsonl` を全文再生成する。stdout の JSON の `expired_keys[]` それぞれに `remember("todo-disposition expired key=<key> written_at=<ISO> reason=ttl\n<title>", type='fact', tags=['todo-disposition','expired','<source>'])` を書く。無人 run はここまで（承認者不在なので inferred は保存しない）。
- **対話実行なら**候補を処置してよい: AskUserQuestion を 4 候補ずつ（承認 / 却下 / 1 週間 snooze / このスレッドは今後除外）。承認 → todo `remember`（`via:todo-approve`）、**却下・snooze・除外は捨てるのではなく disposition レコードとして source の sink へ `remember`** する: `todo-disposition <kind> key=<key> written_at=<ISO>[ until=<YYYY-MM-DD>][ thread_key=<tk>]` + 理由 1 行、`tags:['todo-disposition','<kind>','<source>']`。`thread_key=` を持つレコードだけがスレッド全体を隠す（`never` が書く。`reject` は単独 key）。翌 run の `filter` が反映する。**silent drop 禁止**は変わらない — helper が aged-out / expired / hidden を run log に 1 行ずつ残す

### Step 4b — 承認面（config `surfaces.queue_surface: slack-self-dm` のときだけ）

承認面が有効な config では、候補 1 件 = 承認面の DM 1 通、処置 = DM へのリアクション 1 回。チャンネル id と絵文字名は config の `surfaces.channel` / `surfaces.reactions` から取る（SKILL.md には書かない — workspace 固有の値）。順序が重要:

1. **読取（Step 1 の sweep より前、Step 2 の browse の後）**: 承認面のチャンネルを `slack_read_channel(channel_id: <surfaces.channel>, response_format: "detailed", oldest: <queue 内で最古の open な announce.ts>)` で、`cursor` が尽きるまでページングして読む（`limit` 上限は 100。1 回読みでは古い候補のリアクションを取り逃す）。各メッセージを `{ts, channel, reactions: [{name, count}]}` に整形して `tmp/<RUN_TS>-reactions.json`（`{"messages": [...]}`）に書く。同じ store の todo / disposition レコードのうち本文に `announce=<channel>/<ts>` 行を持つものを `tmp/<RUN_TS>-records.json`（`{"records": [...]}`、`id` / `content` / `provenance` を含める）に書く。
2. **判定は helper**: `python3 … ingest-reactions --reactions <reactions.json> --records <records.json> --run <RUN_TS> --config <config.json>`。stdout の JSON:
   - `actions[]`（`kind ∈ approve|reject|snooze|never`）を 1 件ずつ適用する。approve → `browse(tags:"todo")` で key 既存なら skip（既存なら領収書のみ）、`todos_enum` が truncated なら**保留**して needs_review 相当として run log に「未適用（dedup 不完全）」を書く。未存なら todo `remember`（`via:slack-reaction`、本文 1 行目 `key=`、**2 行目に `announce=<channel>/<ts>`**）。reject / snooze（`until` は helper が計算）/ never（`thread_key=` 付き）→ disposition `remember`（本文に `announce=<channel>/<ts>` 行を含める — 翻意検知に使う）。
   - `needs_review[]`（✅ と ❌ が同時 / DM が `ttl_days` より古い）は helper が queue の `state` を `needs_review` に書き換えている。スレッドに 1 行返信して確認を求める。
   - `revert_candidates[]`（既に approve / reject 済みの key の DM に、それと矛盾するリアクションが付いた）: `source_class` が `tool-output`（この箱が書いた）なら approve の取消 = `forget` + `todo-disposition done … reason=reverted-by-reaction`、reject の取消 = `todo-disposition revive`。`user-stated`（laptop で書かれた）なら箱からは触れないので `needs_review` としてスレッド返信「laptop の `/todo-approve --undo <key>` で取消」。
   - `announce_missing[]`（announce.ts の DM が履歴に見つからない）は run log に列挙する（削除された DM。翌 run の `to_announce` で再送されるよう `set-announce` は触らない — Phase 3 で再送規則を決める）。
   - 領収書はその候補 DM への**スレッド返信** `[todo-loop] ✅ 承認 → <store> <id>` / `❌ 却下を記録` / `💤 <until> まで保留` / `🔇 スレッド除外`（`slack_send_message(channel, thread_ts=<announce.ts>, …)`）。
   - 処置した key の一覧を `tmp/<RUN_TS>-applied.json`（`{"keys": [...]}`）に書き、Step 4 の `filter` に `--applied` で渡す（disposition の browse 結果はこの run の書込より古いので、同日中に隠すため）。
3. **送信（Step 4 の `filter` の後）**: `filter` の stdout `to_announce[]`（`dm_per_run_max` 以内、origin_ts 昇順）を 1 件ずつ `python3 … render-dm --key <key> --config <config.json>` で本文にして `slack_send_message(channel_id: <surfaces.channel>, message: <本文>)` で送り、**送るごとに** `python3 … set-announce --key <key> --channel <channel> --ts <戻り値の message_ts>` を呼ぶ（送信と永続化の窓を 1 件分に閉じる — まとめて後で書くと途中死で翌日二重送信になる）。継続候補は再投稿しない。`announce_pending` はキャップ超過分（翌 run に持ち越し）。
4. 承認面は **ループ自身のメッセージ**にしか触らない（DM 送信・スレッド返信・リアクション読取）。ソース（saved / 📌 / 元メッセージ）は不変のまま。

### Step 5 — run log 作成

`~/.claude/todo/runs/<RUN_TS>-collect.md` を**新規作成**する（1 行目の見出しに RUN_TS）。内容: 実行日時 / ソース別 新規 N 件・候補 M 件・dedup skip 数 / helper の filter 出力の要約（open, needs_review, aged_out, deduped, hidden, expired）/ 未 sweep とその理由 / truncated 残数 / 保存した id / disposition id。helper が同じファイルに `### queue filter` 節（aged-out / expired / hidden を 1 行ずつ）を追記しているので、候補の再叙述はしない。`ledger.md`（index）は書かない。

### Step 6 — Reminders mirror 同期（remind_sync.rb）

Apple Reminders を open memory todo の surface（mirror）として同期する（設計と sync 5 規則: `~/.claude/docs/todo-management.md` の「Apple Reminders integration」）。実装は同 skill ディレクトリの `remind_sync.rb` — 状態ファイルを持たず、毎回 2 つのダンプから plan を導出する（リンクは reminder notes 末尾の `[ai-todo:<memory-id>]` トークンと memory content 内の `reminders:<externalId>` provenance のみ）。

1. **memory dump 作成**: 両 store の `browse(filters: {tags: "todo"}, limit: 500)` 結果（open のみ）を `[{"id","store","content","tags"}]` の JSON に整形して MEM.json へ。
   **打ち切った dump で apply してはならない**: `truncated` が true のまま進めると、`remind_sync` は落ちた分を「memory 側に無い」と読み、sync 規則 5 に従って**まだ open な TODO の reminder を完了させる**。`total` と返却件数が一致しない場合は `limit` を上げて引き直し、それでも一致しなければ Step 6 を skip して run log に `truncated 残数` と skip 理由を残す
2. **config 作成**: sources.yaml + sources.local.yaml の merge 結果から `{"mirror":{...},"capture":{"lists":[...],"sink":"..."}}` を CONFIG.json へ（capture.lists = apple-reminders ソースの query リスト群）
3. **1 回目 apply**: `ruby remind_sync.rb --config CONFIG.json --memory-dump MEM.json --apply`。reminder_actions（mklist→add→annotate→complete）は script 自身が remind CLI で実行する。stdout JSON のうち skill が MCP で実行するのは: `memory_actions`（forget — reminder 完了を機械的証拠として対応 store の todo を閉じる。**forget した todo の本文に `key=` があれば同 store に `todo-disposition done key=<key> written_at=<ISO> reason=reminder-completed` を remember する** — Slack 側の saved / 📌 は残るので、これが無いと翌日再候補化される）と `capture_candidates`（Step 2-4 の dedup→正規化→書込フローに乗せる。explicit なので自動 remember + 領収書）
4. **2 回目 apply**: 同コマンドを再実行 — capture で新規 remember した分への annotate（notes に `[ai-todo:<id>]` 追記）が走って収束する
5. **冪等確認**: 3 回目（`--apply` 無しの plan）で `counts` が全規則 0 件であることを確認。0 でなければ収束失敗 — それ以上書き込まず run log に WARN

件数（add / annotate / complete / forget / capture 候補）と収束確認の結果は Step 5 の run log に追記する。

## 検証ゲート（最重要）

- ソース側の状態を変更しない — Google Task を complete にしない、saved を解除しない、リアクションを消さない
- **Reminders は連携ストア — 非連携 capture ソース（Slack / Google Tasks 等）の不変更原則の例外**: Apple Reminders に限り、リンクトークンの annotate（notes への `[ai-todo:<id>]` 追記）と close 伝播の complete の 2 操作のみ変更可。それ以外（reminder の削除・タイトル編集・リスト移動・トークン以外の notes 書換え）は禁止
- **sink 越境禁止**: work 系 adapter（Mercari Slack 等）の sink が `ai-memory` になっていたら書き込まずに停止して警告（egress 違反）。disposition レコードも同じ sink に書く
- **Slack sweep は全ページ取得を確認**: `End of results` まで辿ったか（1 ページ=20 件ちょうどで止まっていないか）。saved / reaction に `after:` を付けていないか（付けると投稿日フィルタで古い保存分が全部消える）。打ち切る場合は `truncated` + `remaining`（silent cap 禁止）
- inferred 項目は承認なしに書き込まない。actionable でないと判断した分も silent drop せず items に入れ、helper と disposition に判断を任せる
- `candidates.jsonl` と `ledger.md` を直接 Write / Edit しない（前者は helper、後者は runner が書く）
- 書込後、`browse`（`limit` 明示）で着地を確認してから領収書を出す（Verify-before-done）。打ち切られた応答で「着地していない」と判定しない — `total` を見て判断する

## ループ化

**work ソースは sh1-cloud で無人実行**: `todo-collect.timer`（毎日 07:23 JST、zp-SHIN overlay の `mercari-claude-todo` cookbook が配置）。Slack connector が headless から呼べることは 2026-08-17 に実測済み（claude 2.1.233 で `slack_search_public("is:saved")` が 2 連続でヒット）— 以前の「headless では connector が使えない」制約は無効。無人 run は 2 点だけ挙動が変わる: inferred を書き込まず `candidates.jsonl` に残す（承認者不在 — 処置は `/todo-approve` か承認面で）、到達できないソース（gws 401 / remind CLI 不在 / ai-memory 未登録）を `unswept` + 理由で明記する。runner は run log の RUN_TS、queue の meta.run、enum 契約、`remember` 呼び出し数（新規 + disposition）を検査する。

**personal ソースは対話実行のまま**: Reminders mirror（Step 6）と ai-memory sink は air の remind CLI と個人 store に依存するので、その日最初の対話セッション冒頭で起動（`/morning-triage` と対で回すのが自然）。無人 run が積んだ候補は `/todo-approve` で処置する。

`/todo-reconcile`（週 1 の出口 = 棚卸し）とは独立 — collect は「入口」。
