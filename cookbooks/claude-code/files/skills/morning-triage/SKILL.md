---
name: morning-triage
description: |
  平日朝に夜間の開発シグナル（自分の open PR の失敗 CI / レビュー依頼された PR / 自分にアサインされた issue /
  夜間 scheduled workflow の失敗）を横断収集し、優先度つきのローカル triage ledger に書き出す
  Loop Engineering の capstone オーケストレータ skill。CI 失敗には pr-ci-medic を呼ぶ（既定 diagnose）、
  well-scoped な修正は worktree で起案し検証サブエージェント（作成/検査分離）に通す。merge は一切しない・出力はローカル。
  末尾で knowledge-drain も回す。「朝の triage」「morning triage」「夜間の開発状況まとめて」「daily triage」でトリガー。
  注: 自動 merge・自動デプロイはしない。triage と（propose 時の）修正起案までが責務。
user-invocable: true
---

# morning-triage — 朝の triage オーケストレータ

夜間に積もった開発シグナルを 1 つの優先度つき ledger にまとめ、機械的に処理できるもの（CI 失敗）は
pr-ci-medic に委譲する。Addy Osmani の朝ルーチン実例の実装。**「一度設計すれば、各ステップにプロンプトしない」**
を体現するが、検証責任は残すため作成/検査を別サブエージェントに分け、merge は人手に残す。

## 安全境界

- **merge しない・自動デプロイしない**（pr-ci-medic の境界を継承）。
- **出力はローカル**（dated Markdown ledger）。個人 home-lab Cognee / 個人 Notion に業務データを出さない。
  通知が要るなら Mercari 公認チャネルのみ（未設定ならローカルファイル止まり）。
- allowlist リポ（既定: `kouzoh/zp-SHIN`, `shin1ohno/setup`）。
- propose（worktree 修正起案）は opt-in。既定は diagnose（収集＋委譲＋記録のみ）。

## 手順

### Step 0. シグナル収集（allowlist 各リポ）
- **自分の失敗 PR**: `gh pr list --author @me --state open` × `gh pr checks` で赤を抽出。
- **レビュー依頼**: `gh search prs --review-requested @me --state open`。
- **アサイン issue**: `gh search issues --assignee @me --state open`（昨日以降更新分を優先）。
- **夜間 scheduled workflow 失敗**: `gh run list --status failure --created >=<昨日>`。
収集ゼロなら "no overnight signals — skipped" で STOP（graceful empty state）。

### Step 1. triage ledger 作成
`~/.claude/triage/<YYYY-MM-DD>.md`（ローカル）に優先度つきで書く:
P0=自分の失敗 PR（マージブロック中）, P1=レビュー依頼, P2=アサイン issue, P3=scheduled 失敗。
各項目: repo / 種別 / リンク / 一行要約 / 推奨アクション。

### Step 2. CI 失敗を pr-ci-medic に委譲
P0 の各失敗 PR について pr-ci-medic を起動（既定 diagnose、設定で propose）。結果（diagnosed/fixed-pushed/
flagged）を ledger の該当行に追記。

### Step 3. 修正起案（propose のみ・作成/検査分離）
well-scoped な P0 修正について:
- 作成サブエージェント: `git worktree`（`isolation: worktree`）で修正を起案。
- 検査サブエージェント: **別エージェント**が、リポの test/lint/skill 契約に照らして検証（adversarial-review /
  sub-agents ルール準拠）。検査を通ったものだけ pr-ci-medic 経由で PR ブランチに push。merge しない。
- レビュー依頼 PR（他人の）は**コメント下書きを ledger に置くだけ**（自動投稿しない）。

### Step 4. サマリ＋知識配管
ledger 末尾に P0-P3 件数と処理状況のサマリ。最後に knowledge-drain skill を回して
`~/.claude/pending-cognify/*.md` を回収（CHUNKS 検証後のみ削除）。

## ループ化（substrate B）

平日朝のローカル cron。例:

```
CronCreate(cron="33 9 * * 1-5", durable=true,
  prompt="Follow ~/ManagedProjects/setup/cookbooks/claude-code/files/skills/morning-triage/SKILL.md in DIAGNOSE mode for repos kouzoh/zp-SHIN and shin1ohno/setup. Write the dated ledger under ~/.claude/triage/ and report P0-P3 counts. Do not merge or auto-post anything.")
```

CronCreate は 7 日失効・同席前提。propose を無人で回さない。恒久・無人化は自律コード push を含むため設計外
（人の監督下に置く）。検証後に default.rb 登録で `/morning-triage` 化。再利用: [pr-ci-medic], [knowledge-drain]。
