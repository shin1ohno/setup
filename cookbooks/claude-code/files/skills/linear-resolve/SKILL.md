---
name: linear-resolve
description: |
  Linear の issue を human-on-the-loop で処理する polling ループ。`agent` ラベルの
  付いた issue を 1 回 1 件だけ拾い、読み取り専用 probe で実機を観測し、変更を
  ブランチに起こして PR を出し、所見と未決の判断を issue にコメントで返して止まる。
  merge しない・apply しない・main に push しない・破壊的操作をしない、が不変の境界。
  allowlist 外（新規設計・destructive・auth/secret・原因不明・3 回失敗）は
  `agent:needs-human` を付けて停止し、**所有者本人のコメント**でのみ再着手する。
  webhook も公開エンドポイントも AgentSession も使わない（polling のみ）。
  「linear resolve」「Linear の issue を処理して」「agent ラベルの issue を見て」でトリガー。
user-invocable: true
---

# linear-resolve

## なぜ polling で、agent platform を使わないのか

Linear の agent platform（AgentSession / elicitation / stop）は HOTL を一級市民として
設計していますが、配送が webhook 前提で、**公開 HTTPS・5 秒応答・10 秒以内の初回
アクティビティ**を要求します。この fleet は Tailscale 完結で、公開 POST 口を 1 つ増やす
ことのリスク評価（`~/.claude/plans/linear-eval-2026-09-06/` の sec1/sec2）で blocking が
8 件出ました。**うち 6 件はその経路に固有**です。

SH1-5（home-monitor PR #148）を手で 1 周回した結果、この種の作業は
「読む → 読み取り専用で調べる → PR を出す → 判断を返す」で完結し、agent platform を
1 つも使いませんでした。よって polling を採ります。遅延は poll 間隔ぶん（既定 10 分）で、
実測されたベースライン（エスカレーション滞留 261 時間・305 時間）とは桁が 3 つ違います。

## 不変の安全境界（常に守る）

1. **1 run = 1 issue**。複数該当しても `updatedAt` 最古の 1 件だけ
2. **merge しない・apply しない・deploy しない**。成果物は常に PR とコメント
3. **main に push しない・force-push しない**
4. **実機への書き込みをしない**。観測は `probe.sh` の固定サブコマンドのみ
5. **資格情報を自分で読まない**。SSM も鍵も `probe.sh` の中にある
6. allowlist 外は着手前に停止し `agent:needs-human` を付ける
7. 同一 issue で 3 回失敗したら停止
8. `~/.claude/linear-loop.DISABLED` があれば即終了

## allowlist（自律で着手してよい作業クラス）

- 宣言的設定への追記・修正（`devices.tf` の 1 エントリ、cookbook の属性、alert ルール）で、
  **観測で正否を確定できる**もの
- ドキュメント・コメントの修正
- 既知の壊れたリンク / 参照の修正
- **テストのある単一リポジトリのバグ修正**。条件は 4 つすべて:
  1. 原因が `file:line` で特定済みで、issue のコメントに書いてある（推測で埋めない）
  2. 正否が CI（`go test` / `pytest` 等）で確定する。修正と同じ PR に回帰テストを足す
  3. 実機・本番サービス・auth / secret に触れない。provider や cookbook のコードが対象で、
     その効果が実機に届くのは version bump と apply（どちらも allowlist 外）の後
  4. 1 つの PR で 1 つのリポジトリだけを変える。release・tag・version bump・依存の追加は
     しない — それらは PR の「未決の判断」として人間に返す

**allowlist 外（必ず停止）**: 新規のアーキテクチャ、破壊的変更、auth / secret に触るもの、
原因が特定できないもの、実機の設定変更、terraform apply、依存の追加、release / version bump。

2026-09-09 の SH1-6 / SH1-7（terraform-provider-rtx の不具合 2 件）が 4 番目のクラスを
足した契機です。診断は `attempt 1` で `file:line` まで出ていたのに、Go のコード修正が
allowlist 外で止まり、人間が同じ修正を手で書くことになりました。実機に触れず CI で
正否が決まる修正は、宣言的設定の修正と同じ性質です。

## 手順

1. **kill switch と config を確認**。`~/.claude/linear-loop.DISABLED` があれば終了
2. **Linear を polling** する。`agent` ラベルの open issue を取得（GraphQL は下記）
3. **`linear_queue.py select`** に渡して 1 件を選ぶ。`picked` が null なら「対象なし」を
   1 行ログして終了。**この選択にモデルの判断を入れない**
4. **着手コメント**を 1 本書く（`linear-loop attempt N — 着手` + 末尾に `<!-- linear-bot -->`）。
   マーカーを忘れると次サイクルで自分のコメントをユーザー信号と誤認する
5. **調べる**。`probe.sh` で実機を観測し、リポジトリの記録済み知識（`~/.claude/projects/*/memory/`、
   該当リポの CLAUDE.md、docs/runbooks）と突き合わせる。**推測で埋めない**
6. **作業クラスを判定**。allowlist 外なら §7 へ
7. **変更してブランチに commit し、PR を出す**（§リポジトリ別アダプタ）
8. **結果を issue にコメント**: 観測した事実、変更内容、PR リンク、**未決の判断を番号付きで**。
   末尾に `<!-- linear-bot -->`
9. **終端処理**（どちらか一方。飛ばすと無限ループになる）
   - **未決の判断がある** → `agent:needs-human` を付ける
   - **未決なし＝完了** → 報告コメントを `linear-loop done — <要約>` で始め、
     **`agent` ラベルを外す**
10. **止まる**

## 終端 — 「完了・未決なし」を必ず表明する

`agent` ラベルは「ループが触ってよい」の意味なので、**終われば真でなくなります**。
完了時にラベルを外さないと、10 分ごとに同じ issue を選び直し、同じ調査とコメントを
繰り返し、attempt 3 で打ち止めになります。2026-09-08 の L3 実走で実際に踏みました。

**表明は 2 系統**用意します。ラベル除去は失敗しうるミューテーションだからです。

1. 報告コメントを `linear-loop done — <要約>` で始める（末尾に `<!-- linear-bot -->`）
2. `agent` ラベルを外す

コメントは landed したがラベル除去が失敗した、という中途半端な状態でも、
`linear_queue.py` は done マーカーを見て停止します。逆も同じです。

**終端は撤回可能です。** done のあとに**所有者本人**がコメントすれば
`done but the operator replied` として復活します。撤回できない終端状態は、
setup#963 が GitHub 側から取り除いた「永久ロック」を作り直すことになります。
第三者のコメントでは復活しません。

## 停止して人間に返すとき

コメントに次を書き、`agent:needs-human` を付けて終了します。

- 何を観測したか（コマンドと出力の要点）
- なぜ自律で進めないのか（allowlist のどの条件か）
- **番号付きの選択肢**（あなたは番号で答えるだけでよい形にする）

あなたがコメントで答えると、次の poll が `linear_queue.py` の所有者判定で拾い、
`agent:needs-human` が付いたままでも再着手します。

## 所有者判定 — ここを間違えると永久に無視される

ループは**あなたの個人 API キー**で書くので、**ループのコメントの著者はあなた自身**です。
著者 id では bot と人間を分離できません（GitHub で 77 日・170 issue・通知 0 件を生んだのと
同じ構造）。したがって判定は **`<!-- linear-bot -->` マーカーの完全一致 1 本のみ**で行います。

setup#963 の教訓: マーカーに加えて「ループの名前を含むか」という**無アンカーの部分文字列**
一致を足したせいで、`self-heal-resolve のログを見た。1 で進めて` という GO が bot 判定され、
その issue は二度と actionable になりませんでした。**パターンを増やさないこと**が対策です。

## リポジトリ別 PR アダプタ

| remote | PR 作成 | チェック |
|---|---|---|
| GitHub | `gh pr create` → `gh pr checks <n> --watch` | CI |
| `codecommit::` | `aws codecommit create-pull-request` | CI 無し。`terraform fmt -check` と `validate` をループ側で実行し、結果を PR 本文に書く |

判定は `git remote get-url origin` が `codecommit::` で始まるか。**home-monitor には `gh` が
ありません** — SH1-5 で実証済みです。

## GraphQL（polling）

```graphql
query($label: String!) {
  issues(filter: { labels: { name: { eq: $label } },
                   state: { type: { neq: "completed" } } }, first: 50) {
    nodes { id identifier title description updatedAt url
            labels { nodes { name } }
            comments { nodes { id body createdAt user { id } } } }
  }
}
```

`Authorization: <個人 API キー>`（`Bearer` は付けない）を `https://api.linear.app/graphql` へ。

## 設定

| 変数 | 既定 | 用途 |
|---|---|---|
| `LINEAR_API_KEY` | — | 個人 API キー。runner が env で渡す |
| `LINEAR_OWNER_ID` | — | あなたの Linear user id（`{ viewer { id } }` で取得） |
| `LINEAR_AGENT_LABEL` | `agent` | 対象ラベル |
| `LINEAR_NEEDS_HUMAN_LABEL` | `agent:needs-human` | 停止ラベル |
| `LINEAR_PROBE_AWS_PROFILE` | `linear-probe` | probe 専用の読み取り専用 IAM。**`sh1admn` を入れないこと** |

## ループ化

runner（systemd timer、既定 10 分）から `claude -p` で起動します。permission mode と
tool clamp は runner 側で固定し、`~/.claude/settings.json`（USER スコープ）に置きます —
project / local スコープはブランチの中身であり、ループ自身が編集できるためです。

**未実装**: runner と timer、専用 IAM は別 PR です。この PR の時点では、この skill は
手動起動でのみ動きます。
