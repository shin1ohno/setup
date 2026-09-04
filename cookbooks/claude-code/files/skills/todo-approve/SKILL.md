---
name: todo-approve
description: |
  /todo-collect が ~/.claude/todo/candidates.jsonl に残した承認待ち候補（inferred な
  capture）を 4 件ずつ AskUserQuestion で処置する対話 skill。承認 = その source の sink
  （memory store）へ todo レコードを remember、却下 / 1 週間 snooze / スレッド除外 =
  同じ store へ append-only の todo-disposition レコードを remember。取消系は
  --revive <key>（却下・除外の取消）/ --undo <key>（承認の取消 = forget + done）/
  --apply-air-pending（laptop 限定 — 箱が forget できなかった user-stated todo の一括処置）。
  ローカルファイル（candidates.jsonl / ledger.md / runs/ / stores.json / surfaces.json）は
  一切 Write しない — 翌朝の collect が disposition を読んで queue から落とす。処置後は
  Canvas（surfaces.canvas: auto のとき）を render-canvas --exclude で全文置換する。
  `--list` は helper の summary をそのまま出す。
  「todo approve」「候補を処置」「TODO 承認」「承認待ち見せて」「候補見せて」でトリガー。
  設計の真実源は ~/.claude/docs/todo-management.md（Queue / Dispositions / Canvas）。
user-invocable: true
---

# todo-approve

## 目的

TODO 管理パイプラインの「承認」段。無人 collect は inferred 候補を保存せず `~/.claude/todo/candidates.jsonl`（O(open) のキュー）に残す。この skill はそのキューを 1 問 4 候補で回し、決定を **store of truth（memory store）に append-only で書く**。queue 側の反映は翌 collect run の `todo_queue.py filter` が行うので、この skill はローカルファイルを書かない — 2 writer 問題を構造的に避ける。承認面（self-DM のリアクション）と同じ台帳に書くので、どちらで処置しても翌 run の見え方は同じ。

## 前提

- helper: `python3 ~/.claude/skills/todo-collect/todo_queue.py`（無ければ停止して「公開 claude-code cookbook を apply」と言う）。
- キュー: `~/.claude/todo/candidates.jsonl`。無い場合は `ssh -o BatchMode=yes -o ConnectTimeout=5 "$TODO_QUEUE_HOST" cat ~/.claude/todo/candidates.jsonl`（`TODO_QUEUE_HOST` は env か config `queue.host`）を `$TMPDIR/todo-approve/candidates.jsonl` に保存し、以降の helper 呼び出しに `--queue <そのパス>` を付ける（**リモート queue モード**。Canvas 更新は行わない — 箱の翌 collect が更新する）。取得できなければ「未列挙（キューに到達できない）」と 1 行言って停止する — Canvas や ledger から推測して処置しない。
- config: `~/.claude/todo/sources.yaml` + `sources.local.yaml` を読み、`queue:` / `surfaces:` / `sources[]` を JSON にして `$TMPDIR/todo-approve/config.json` に書く（helper は YAML を読めない）。`surfaces.canvas` と `surfaces.channel` / `reactions` はここから取る。
- 排他 probe: `flock -n /tmp/todo-loops.lock true` を 1 回試す。取れなければ「collect / reconcile が実行中。N 分後に再実行」で停止。Bash 呼び出し間でロックは保持できないので probe のみ — 書込は append-only なので、残る競合は同一 key の二重 disposition（latest-wins で無害）に限られる。
- identity: このホストが箱（`hostname` = `sh1-dev-instance-1`）なら書込は `tool-output`、laptop なら `user-stated`。1 問目の前置きに 1 行で明示する（user-stated は箱の週次 reconcile が forget できず air 待ちになる / tool-output は箱が証拠付きで forget できる）。

## `--list`

`python3 ~/.claude/skills/todo-collect/todo_queue.py summary` の出力をそのまま示して終了（リモート queue モードでは `summary` はローカルの状態しか見ないので、代わりに `render-canvas --section 1 --queue <取得した queue> --config <config.json>` と `--section 2` の出力を示す）。

## 本処理（既定）

1. キューを読む。meta の `run` が 30 時間より古い、または `dispositions_enum.state != complete` なら冒頭に 1 行警告（「collect が止まっている / 前回 run の disposition 列挙が不完全」）。
2. `state ∈ {open, needs_review}` の候補を `origin_ts` 昇順に並べ、**AskUserQuestion 1 問 = 4 候補**（各候補が 1 question、選択肢は 承認 / 却下 / 1 週間 snooze / このスレッドは今後除外）。質問文に: タイトル / 期日 / 経過日（origin_ts 起点）/ permalink / 起草した完了条件 / `needs_review` なら理由（✅❌同時、DM が古い、翻意候補）。
3. 決定を **その候補の source の `sink`** へ書く（work source → memory-work 固定。sink が個人 store の work 候補は書かずに停止 = egress 違反）。候補に `announce`（DM）があれば本文に `announce=<channel>/<ts>` 行を含める（承認面と同じ翻意検知に乗る）:
   - **承認** → `remember(content, type='fact', tags=['todo','<source>','via:todo-approve'])`。content の 1 行目は `key=<key>`、以降に 完了条件（起草値を確認し、必要なら質問の自由記述で差し替え）/ 対象 / 想定 class / provenance（permalink）。
   - **却下** → `remember("todo-disposition reject key=<key> written_at=<ISO>\n<理由 1 行>", type='fact', tags=['todo-disposition','reject','<source>'])`
   - **1 週間 snooze** → `remember("todo-disposition snooze key=<key> written_at=<ISO> until=<today+snooze_days>\n<title>", …tags=['todo-disposition','snooze','<source>'])`（`snooze_days` は config `queue.snooze_days`、既定 7）
   - **このスレッドは今後除外** → `remember("todo-disposition never key=<key> written_at=<ISO> thread_key=<thread_key>\n<title>", …tags=['todo-disposition','never','<source>'])`。`thread_key=` を持つレコードだけがスレッド全体を隠す（reject は単独 key のみ）。
4. 書込後に `browse(filters:{tags:"todo"}, limit:500)` / `browse(filters:{tags:"todo-disposition"}, limit:500)` で着地を確認（`total` 突合）してから領収書を 1 行ずつ出す（「→ memory-work に保存。完了条件: X」/「→ disposition reject 記録（翌 collect で queue から消える）」）。候補に DM があれば、その DM へスレッド返信 `[todo-loop] ✅ 承認 → <store> <id>` 等も 1 行送る（承認面の領収書と同じ形。ソースには触らない）。
5. **Canvas 更新**（下記）。
6. 最後に処置件数を 1 行: `todo-approve: 承認 a / 却下 r / snooze s / never n`。

## `--revive <key>`

却下・スレッド除外・期限切れの取消。翌 collect run で候補に戻る（Slack ソースに残っていれば）。

1. `browse(filters:{tags:"todo-disposition"}, limit:500)` から `key=<key>` の最新レコード（`written_at` 最大）を引く。無い、または最新が `revive` → 「<key> に有効な disposition が無い（revive 対象なし）」で停止。最新が `done` のときは reason が `undo-by-operator` / `reverted-by-reaction`（operator 起源）に限り続行、それ以外（reconcile の証拠付き done、reminder-completed）は「done は revive しない — 実体が閉じている」で停止。
2. AskUserQuestion 1 回（理由の自由記述可）。
3. `remember("todo-disposition revive key=<key> written_at=<ISO>[ thread_key=<tk>]\n<理由>", type='fact', tags=['todo-disposition','revive','<source>'])`。`<source>` と `thread_key=` は元レコードから引き継ぐ（`never` の取消はスレッド全体の除外解除）。
4. `browse` で着地確認 → 領収書 1 行。Canvas 更新は不要（queue に行が無いので表は変わらない）。

## `--undo <key>`

承認の取消 = 保存済み todo の `forget` + `todo-disposition done`。`done` が無いと Slack ソースは不変なので翌日再候補化する — 同 turn で必ず書く。

1. `browse(filters:{tags:"todo"}, limit:500)` から本文に `key=<key>` 行を持つ todo を引く。無ければ「<key> の todo が無い（承認されていない）」で停止。
2. provenance を見る: 箱では `tool-output` の doc だけ forget できる。`user-stated` なら「laptop の `/todo-approve --undo <key>` で取り消す」と言って停止。laptop では両方試み、`forget` が拒否されたら理由を表示して停止。
3. AskUserQuestion 1 回（タイトルと id を見せて確認）。
4. `forget(<id>)` → 同 store に `remember("todo-disposition done key=<key> written_at=<ISO> reason=undo-by-operator[ announce=<channel>/<ts>]\n<title>", type='fact', tags=['todo-disposition','done','<source>'])`。
5. `browse` で todo が消え disposition が着地したことを確認 → 領収書。候補として再判断したい場合は続けて `--revive <key>`（undo 由来の done は revive 可）。
6. Canvas は触らない（queue に行は無い。§3 の store 別 open は翌 collect の `set-store` が反映する）。

## `--apply-air-pending`（laptop 限定）

箱（service account）が `forget` できなかった user-stated todo の一括処置。追跡 todo（`tags:['todo','work','air']`、本文に対象 id と probe 証拠 1 行ずつ）を reconcile が起票している。

1. `hostname` が `sh1-dev-instance-1` なら「箱では処置不能。laptop で実行」で停止。
2. `browse(filters:{tags:"air"}, limit:500)` → 追跡 todo を全部読み、列挙された id ごとに `get(<id>)` でタイトルを取る。
3. AskUserQuestion 1 回（multiSelect、既定は全件 — 各 option に タイトル + 証拠行）。
4. 選ばれた id ごとに `forget(<id>)` → 本文に `key=` があれば `remember("todo-disposition done key=<key> written_at=<ISO> reason=<証拠行>", type='fact', tags=['todo-disposition','done','<source>'])`。
5. 追跡 todo: 列挙 id が全部処置済みなら `forget`（key 無しなので done 不要）。一部なら `revise(<追跡 id>, <残り id だけの本文>)`（追跡 todo は disposition ではないので revise 可）。
6. 領収書: `air-pending: forget N / done N / 残り M`。`stores.json` の `air_pending_forget` は箱の翌 reconcile が更新する（laptop から書かない）。

## Canvas 更新（処置後）

config `surfaces.canvas: auto` かつローカル queue モードのときだけ。リモート queue モードと laptop では行わない（「Canvas は箱の翌 collect run が更新」と 1 行言う）。

1. `python3 … render-canvas --json --config <config.json> --exclude <この session で処置した key をカンマ区切り>` → `{canvas, markdown}`。`canvas` が null なら何もしない（初回作成は collect の仕事）。
2. `slack_read_canvas(canvas.id)` → 先頭（title）以外の最初の section を `replace`（content = markdown 全文）、残りの body section を `delete` する 1 回の `slack_update_canvas`（collect の Step 5.5 と同じ全文置換。見出しと本文は別 section で id は毎回変わる）。
3. 成功したら `python3 … set-canvas --id <id> --url <url>`（`--run` は付けない — run 外の更新。`last_run` は保持される）。失敗は 1 行報告して続行（Canvas は view）。

## 禁止

- `candidates.jsonl` / `ledger.md` / `runs/` / `stores.json` / `surfaces.json` への直接 Write（collect / runner / reconcile / helper 所有。`set-canvas` だけがこの skill から helper 経由で `surfaces.json` を更新する）
- Slack ソースの状態変更（saved 解除・📌 削除・元メッセージへの返信）、TODO.md や issue の複製、別 Canvas の新規作成
- `forget` / `revise` は `--undo` と `--apply-air-pending` の定義済み経路のみ（disposition レコードは append-only。取り消しは `revive` で上書きする）
- work 候補を個人 store に書く（sink 越境 = egress 違反）
