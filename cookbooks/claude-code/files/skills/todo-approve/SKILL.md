---
name: todo-approve
description: |
  /todo-collect が ~/.claude/todo/candidates.jsonl に残した承認待ち候補（inferred な
  capture）を 4 件ずつ AskUserQuestion で処置する対話 skill。承認 = その source の sink
  （memory store）へ todo レコードを remember、却下 / 1 週間 snooze / スレッド除外 =
  同じ store へ append-only の todo-disposition レコードを remember。ローカルファイル
  （candidates.jsonl / ledger.md / runs/）は一切書かない — 翌朝の collect が disposition を
  読んで queue から落とす。`--list` は helper の summary をそのまま出す。
  「todo approve」「候補を処置」「TODO 承認」「承認待ち見せて」「候補見せて」でトリガー。
  設計の真実源は ~/.claude/docs/todo-management.md（Queue / Dispositions）。
user-invocable: true
---

# todo-approve

## 目的

TODO 管理パイプラインの「承認」段。無人 collect は inferred 候補を保存せず `~/.claude/todo/candidates.jsonl`（O(open) のキュー）に残す。この skill はそのキューを 1 問 4 候補で回し、決定を **store of truth（memory store）に append-only で書く**。queue 側の反映は翌 collect run の `todo_queue.py filter` が行うので、この skill はローカルファイルを書かない — 2 writer 問題を構造的に避ける。

## 前提

- helper: `python3 ~/.claude/skills/todo-collect/todo_queue.py`（無ければ停止して「公開 claude-code cookbook を apply」と言う）。
- キュー: `~/.claude/todo/candidates.jsonl`。無い場合は `ssh -o BatchMode=yes -o ConnectTimeout=5 "$TODO_QUEUE_HOST" cat ~/.claude/todo/candidates.jsonl`（`TODO_QUEUE_HOST` は env か config `queue.host`）。取得できなければ「未列挙（キューに到達できない）」と 1 行言って停止する — Canvas や ledger から推測して処置しない。
- 排他 probe: `flock -n /tmp/todo-loops.lock true` を 1 回試す。取れなければ「collect / reconcile が実行中。N 分後に再実行」で停止。Bash 呼び出し間でロックは保持できないので probe のみ — 書込は append-only なので、残る競合は同一 key の二重 disposition（latest-wins で無害）に限られる。

## `--list`

`python3 ~/.claude/skills/todo-collect/todo_queue.py summary` の出力をそのまま示して終了。

## 本処理

1. キューを読む。meta の `run` が 30 時間より古い、または `dispositions_enum.state != complete` なら冒頭に 1 行警告（「collect が止まっている / 前回 run の disposition 列挙が不完全」）。
2. `state ∈ {open, needs_review}` の候補を `origin_ts` 昇順に並べ、**AskUserQuestion 1 問 = 4 候補**（各候補が 1 question、選択肢は 承認 / 却下 / 1 週間 snooze / このスレッドは今後除外）。質問文に: タイトル / 期日 / 経過日（first_seen 起点）/ permalink / 起草した完了条件。1 問目の前置きに 1 行: 「このホストで承認すると <user-stated|tool-output> として保存されます（user-stated は sh1-cloud の週次 reconcile が forget できず air 待ちになる / tool-output は箱が証拠付きで forget できる）」。
3. 決定を **その候補の source の `sink`** へ書く（work source → memory-work 固定。sink が個人 store の work 候補は書かずに停止 = egress 違反）:
   - **承認** → `remember(content, type='fact', tags=['todo','<source>','via:todo-approve'])`。content の 1 行目は `key=<key>`、以降に 完了条件（起草値を確認し、必要なら質問の自由記述で差し替え）/ 対象 / 想定 class / provenance（permalink）。
   - **却下** → `remember("todo-disposition reject key=<key> written_at=<ISO>\n<理由 1 行>", type='fact', tags=['todo-disposition','reject','<source>'])`
   - **1 週間 snooze** → `remember("todo-disposition snooze key=<key> written_at=<ISO> until=<today+7>\n<title>", …tags=['todo-disposition','snooze','<source>'])`
   - **このスレッドは今後除外** → `remember("todo-disposition never key=<key> written_at=<ISO> thread_key=<thread_key>\n<title>", …tags=['todo-disposition','never','<source>'])`。`thread_key=` を持つレコードだけがスレッド全体を隠す（reject は単独 key のみ）。
4. 書込後に `browse(filters:{tags:"todo"}, limit:500)` / `browse(filters:{tags:"todo-disposition"}, limit:500)` で着地を確認（`total` 突合）してから領収書を 1 行ずつ出す（「→ memory-work に保存。完了条件: X」/「→ disposition reject 記録（翌 collect で queue から消える）」）。
5. 最後に処置件数を 1 行: `todo-approve: 承認 a / 却下 r / snooze s / never n`。

## 禁止

- `candidates.jsonl` / `ledger.md` / `runs/` / `stores.json` への書込（collect / runner / reconcile 所有）
- Slack ソースの状態変更（saved 解除・📌 削除）、TODO.md や issue の複製
- `forget` / `revise`（disposition は append-only。取り消しは Phase 3 の `--undo` / `--revive`）
- work 候補を個人 store に書く（sink 越境 = egress 違反）

## 後続 Phase（未実装）

`--revive <key>`（`todo-disposition revive`）、`--undo <key>`（approve 済み todo の forget + `done`）、`--apply-air-pending`（air 待ちの user-stated forget 一括処置）、処置後の Canvas 更新。
