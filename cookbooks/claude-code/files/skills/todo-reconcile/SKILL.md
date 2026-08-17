---
name: todo-reconcile
description: |
  全 TODO ストア（各 repo の TODO.md、ai-memory / memory-work の tags:["todo"]、
  federated な GitHub issues）を横断列挙し、項目ごとに 2 秒 probe で stale を検出して
  済み / 前提消滅 / 継続 / 要判断 に分類する、TODO 管理パイプラインの週次棚卸しループ skill。
  probe なしの即答列挙（list モード）も担当。結果は ~/.claude/todo/ledger.md に書き出す。
  ストア設計・capture routing は ~/.claude/docs/todo-management.md が真実源。
  デフォルトは dry-run（列挙 + probe + 分類提案のみ。forget も TODO.md 編集もしない）。
  「todo reconcile」「TODO 棚卸し」「TODO 掃除」で dry-run、
  「TODO 見せて」「open な TODO は」で list モード、「LIVE mode」明記で適用モード。
  注: forget / TODO.md 編集は機械的証拠か明示承認がある場合のみ。TODO.md 編集は
  PR 経由（main 直 push 禁止）。issues と TODO.md は列挙するだけで複製しない。
user-invocable: true
---

# todo-reconcile

## 目的

TODO 管理パイプライン（`~/.claude/docs/todo-management.md`）の「完了 / 棚卸し」段を担う。TODO の状態は open（存在する）か deleted（済み / 前提消滅）の 2 つだけ — この skill は閉じ忘れ・前提消滅・期日超過を週 1 で検出して掃除する。closure の一次防衛は各セッションの完了報告内蔵の evidence-based auto-close であり、この skill はその backstop。

## モード

起動プロンプトの語で判定:

- 「TODO 見せて」「open な TODO は」 → **list**: probe なし。列挙 + テーマ別グルーピングを即答して終了
- （既定） → **dry-run**: 列挙 + probe + 分類 + 提案。書き込みは ledger のみ
- 「LIVE mode」の語がある → **LIVE**: dry-run の全処理 + 承認済みアクションの適用

## 手順

### Step 0 — 列挙（全モード）

1. TODO.md 横断: `ls ~/ManagedProjects/*/TODO.md` → 各ファイルの `##` エントリを抽出（description / first step / dated status を保持）
2. memory: 到達可能な store それぞれで `browse(filters: {tags: "todo"}, limit: 500)`（ai-memory と memory-work の両方）。片方に到達できない場合は WARN して続行し、その store の項目は「未列挙」として ledger に明記する — 「0 件」と報告してはならない
   - **`limit` を明示し、返却が全件かを `total` と突き合わせる**: `browse` は cursor を持たないので、`limit` を省くとサーバ既定の 50 件で無言に切れる。応答の `total` が返却件数より大きい（= `truncated: true`）場合は `truncated 残数 = total - 返却件数` を ledger に明記し、tag を足す / store を分ける等でクエリを狭めて残りを引く。`total` を返さない旧サーバ相手では「返却件数がちょうど `limit`」を打ち切りの tell とする（Slack sweep と同じ silent cap 禁止の規律）
3. federated issues: `gh search issues --assignee=@me --state=open`（+ shin1ohno/setup の open self-heal issues）。読み取り列挙のみ — memory へ複製しない
4. legacy sweep（移行期のみ）: tag なしで memory に漏れ込んだ TODO 形エントリを `recall`（例: query「TODO 未完了 あとで deferred 作業」, top_k=15）で拾い、候補として提案する（処置は tags:["todo"] 付き再保存 or forget、Step 2 の承認フローに乗せる）

list モードはここで整形出力（store 別 → テーマ別、期日つきは期日順）して終了。

### Step 1 — probe（dry-run / LIVE）

項目ごとに完了条件に対応する 2 秒 probe を 1 つ実行する:

- file 存在: `test -f` / `ls`
- 実装済み: `git -C <repo> log --oneline --grep='<keyword>' -5` / `rg '<keyword>'`
- PR / issue 状態: `gh pr view <n> --json state` / `gh issue view <n> --json state`
- ホスト状態（該当時のみ）: `ssh -o ConnectTimeout=5 <host> '<check>'`

機械 probe 不能な項目（個人タスク等）は「要判断」へ。期日が 7 日以内の項目は「期日接近」フラグを付ける。

### Step 2 — 分類と承認

各項目を分類: **済み**（probe が証拠を返した）/ **前提消滅**（対象がもう存在しない・方針転換済み）/ **継続**（open のまま妥当）/ **要判断**（機械判定不能）。

分類テーブルを提示し、済み・前提消滅・要判断・legacy 候補を AskUserQuestion バッチで確認する（5+ 件はテーマ別にグルーピング）。dry-run はここまで — 提案と ledger 書き出しのみで終了。

### Step 3 — ledger 書き出し（dry-run / LIVE）

`~/.claude/todo/ledger.md` に自分のセクションを**追記**する（`mkdir -p ~/.claude/todo`）。先頭に「生成物 — 手編集禁止（真実源は各 store）」の注記。内容: 実行日時 / モード / store 別 open 一覧 / 分類結果 / 期日接近 / 未列挙 store の WARN / 列挙が打ち切られた store の `truncated 残数`。

**collect の「候補（未承認）」セクションは消さない**。ledger は生成物だが、同時に collect が inferred 候補を置く場所 = 承認待ちキューそのもの（無人 collect は候補を書くだけで保存しない）。全文再生成すると未承認候補が消え、日次 collect + 週次 reconcile の組み合わせでは 1 週間分が消える。過去の自分のセクションを畳むのは可、candidate セクションは残す。

3 値を混ぜないこと: **未列挙**（store に到達できなかった = 不明）/ **0 件**（store が応答して空）/ **truncated 残数**（一部だけ既知）。打ち切りを「0 件」や「未列挙」に丸めると、消えた TODO と見ていない TODO が区別できなくなる。

### Step 4 — 適用（LIVE のみ）

承認済みアクションを適用する:

- memory todo: `forget(id)`。legacy 再保存は `remember(content, type='fact', tags=['todo'])`（完了条件を補筆）+ 元エントリ forget
- TODO.md: 対象 repo でブランチ作成 → エントリ削除 / dated status 追記 → commit → PR（`~/.claude/rules/git-commit.md` 規律。main 直 push 禁止）
- 適用後: 該当 store を再列挙し（同じく `limit` 明示 + `total` 突き合わせ）、消えた / 更新されたことを確認してから完了報告（Verify-before-done）。打ち切られた再列挙で「消えた」と判定してはならない — 見えていないだけの可能性がある

## 検証ゲート（最重要）

- forget / TODO.md エントリ削除は、機械的証拠（probe 出力）か明示承認のどちらかなしに実行しない
- 到達できなかった store の項目を「なし」と報告しない — 「未列挙」と明確に区別する
- ledger は生成物。ledger 上の記述を真実として読み込まない（真実源は常に各 store）
- issues / TODO.md エントリを memory へ複製しない（federation 原則 — split-brain 防止）

## ループ化

**sh1-cloud で週次 LIVE 無人実行**: `todo-reconcile.timer`（月曜 08:13 JST、zp-SHIN overlay の `mercari-claude-todo` cookbook が配置）。無人 run の書込境界は 2 点で通常の LIVE と異なる: (a) forget は 1 run 上限つき（既定 15 件）で機械的証拠のあるものだけ、(b) TODO.md はループ専有の worktree 内で commit までを skill が行い、**push と `gh pr create` は runner shell 側**が実行する（merge は誰もしない）。ai-memory はこのホストに未登録なので個人 store は毎回「未列挙」。

対話セッションからの手動起動（dry-run / list モード）はこれまでどおり。`/todo-collect`（毎日、外部ソースからの capture 収集）とは独立のループ — collect が「入口」、reconcile が「出口」。
