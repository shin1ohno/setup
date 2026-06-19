---
name: pr-ci-medic
description: |
  自分が author の open PR で CI が失敗しているものを巡回し、失敗ログを読んで原因と修正を特定する
  Loop Engineering の自律 PR/CI 修繕ループ skill。既定は diagnose（原因＋修正案を ledger に記録、コード push なし）、
  opt-in で propose（git worktree で修正→ローカル検証→PR ブランチに push、merge はしない）。
  merge しない・main に push しない・force-push しない・他人の PR に触れない、が不変の安全境界。
  「PR の CI 直して」「failing CI を修正」「pr ci medic」「open PR の赤を見て」でトリガー。
  注: merge やリリースは絶対に自動でしない。修繕の提案までが本 skill の責務。
user-invocable: true
---

# pr-ci-medic — 自律 PR/CI 修繕ループ

自分の open PR の失敗 CI を巡回し、原因を診断して（propose モードなら）修正を PR ブランチに push する。
Addy Osmani「無人ループは無人でミスするループ」への答えとして、**既定は push しない diagnose モード**、
コード変更は明示 opt-in、merge は常に人手。

## 不変の安全境界（モードに関わらず常に守る）

1. **対象は自分が author の open PR のみ**（`gh pr list --author @me --state open`）。他人の PR には一切触れない。
2. **allowlist リポのみ**（既定: `kouzoh/zp-SHIN`, `shin1ohno/setup`）。リスト外は対象外。
3. **merge しない**。`gh pr merge` は本 skill では決して実行しない。
4. **main/master に push しない**。push 先は常に PR の既存ブランチのみ。
5. **force-push しない**（`--force`/`-f` 禁止）。共有ブランチの履歴を壊さない。
6. **secret/認証/署名関連の失敗は自動修正しない** — 必ず diagnose に留めて人にフラグ（誤修正が漏洩・権限事故になる）。
7. **曖昧な失敗は diagnose 止まり**: 原因が複数候補に割れる、または修正がスコープ外に波及するなら push せず人にフラグ。
8. **試行上限**: 1 PR あたり 1 回の実行で最大 2 修正試行。green にならなければ diagnose にフォールバックして次へ（fix-loop を回し続けない）。

## モード

- **diagnose（既定）**: 失敗ログを読み、原因＋具体的な修正案をローカル ledger に書く。コードは触らない・push しない。
- **propose（opt-in）**: 上記に加え、`git worktree` で隔離して修正を適用し、**そのリポのローカル検証**（test/lint/build）を
  通してから PR の既存ブランチに通常コミットを push する。**merge は依然しない**。

起動プロンプトに "propose mode" の語が無ければ diagnose。

## 手順

### Step 0. 対象 PR 列挙
allowlist 各リポで `gh pr list --repo <r> --author @me --state open --json number,headRefName,title`。
各 PR の `gh pr checks <n> --repo <r>` で失敗チェックを抽出。失敗ゼロなら "no failing PRs — skipped" で STOP。

### Step 1. 失敗ログ取得
失敗 PR ごとに `gh run view <run-id> --repo <r> --log-failed`（または失敗 job の log）で実エラーを読む。

### Step 2. 原因診断
失敗の class を分類: lint/format / type / test / build / flaky(再実行で直る) / secret・auth(自動修正禁止) / config。
flaky 疑いは `gh run rerun <id> --failed` を 1 回だけ試す（コード変更でない）。

### Step 3. 修正
- **diagnose**: ledger に `repo / PR# / 失敗 class / 根本原因 / 提案修正（具体的 diff か手順）` を記録。push しない。
- **propose**: `git worktree add` で隔離 → 修正適用 → **ローカル検証**（リポの test/lint コマンド。Rust は `~/.claude/rules/rust.md` の 4 チェック、JS は build、cookbook は mitamae dry-run / `bin/lint-cookbooks`）→ 通れば PR ブランチに push → `git worktree remove` → `gh pr checks <n>` を再確認。検証が通らない修正は push しない。

### Step 4. サマリ
処理した PR ごとに `diagnosed / fixed-pushed / flaky-rerun / flagged-for-human / skipped` を ledger に記録して報告。

## 検証ゲート（propose のみ）

push 前に**必ずローカル検証を通す**。「CI が言う修正」を当てずっぽうで push しない — ローカルで同じ失敗を
再現・解消してから push する（observe→fix→re-observe）。検証コマンドが不明なリポは propose せず diagnose に留める。

## ループ化（substrate B / 半自動）

morning-triage から呼ばれるのが主。単独 cron も可だが、自律コード push は同席運用を推奨:

```
CronCreate(cron="23 9 * * 1-5", durable=true,
  prompt="Follow ~/ManagedProjects/setup/cookbooks/claude-code/files/skills/pr-ci-medic/SKILL.md in DIAGNOSE mode for repos kouzoh/zp-SHIN and shin1ohno/setup. Report the ledger.")
```

propose モードを無人で回さない（CronCreate は 7 日失効・同席承認前提）。恒久・無人は本 skill の設計外
（自律コード push は人の監督下に置く）。検証後に default.rb 登録で `/pr-ci-medic` 化。
