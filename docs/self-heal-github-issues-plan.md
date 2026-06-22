# self-heal: GitHub Issues 経路への移行プラン

**Date**: 2026-06-22
**Supersedes notification side**: SNS (PR #514 + home-monitor #96) → GitHub Issues
**確定方針** (AskUserQuestion 2026-06-22):
1. Issue 作成は **pro-dev 側の新 loop** (CT111 observer は ES state 書き込みのみ、fleet LXC に GitHub 秘密鍵を置かない)
2. resolve loop は **完全自律** (調査→fix→PR→CI→merge→auto-mitamae 適用→検証→issue close)
3. SNS 経路は **削除** (observer から除去 + home-monitor #96 revert)

## アーキテクチャ

```
CT111 observer (既存・改修)
  └─ Kibana alerts-as-data を 5min poll → self-heal-state (ES) に open/resolved 書込
     [SNS publish を全削除。遷移検知ロジックは維持＝Loop A の真実源]

pro-dev (新規・確認済み: ES 3 ノード到達可 / CA 有 / gh repo スコープ認証済):
  Loop A  self-heal-create   (/loop)
    └─ self-heal-state open docs を read-only 取得
    └─ open GitHub issue (label:self-heal, body 内 marker) と diff
    └─ 不足を gh issue create / ES で resolved を gh issue close + comment
       ※ ES 書込なし・mapping 変更なし。GitHub が issue レジストリ

  Loop B  self-heal-resolve  (/loop)
    └─ open self-heal issue を 1 件選択 → 着手 comment
    └─ 調査 → cookbook 修正 → lint+dry-run → PR → CI green → merge
    └─ auto-mitamae (CT115 cron) が origin/main を canary→fleet 適用
    └─ 機能状態を検証 → issue close (修正内容/PR/検証エビデンス comment)
```

## 冪等性 (二重 issue を作らない)

- ES `self-heal-state`: 既存の dedup (status open/resolved, dedup_key)
- GitHub: issue body に hidden marker `<!-- self-heal-key:<sha1(dedup_key)> -->`。
  Loop A は毎回 (ES open docs) と (open self-heal issues by marker) を集合 diff →
  不足のみ create、ES で消えたもののみ close。再実行で no-op。

## Phase 1 — Loop A (issue 作成) ※先に通知を成立させる

設置物 (setup repo):
- `cookbooks/claude-code/files/skills/self-heal-create/SKILL.md`
  手順: SSM から elastic pw 取得 → `GET /self-heal-state/_search status:open` →
  `gh issue list --repo shin1ohno/setup --label self-heal --state open --json number,body` →
  marker で diff → `gh issue create` / `gh issue close --comment`。
- `gh label create self-heal` (1 回) + `self-heal-needs-human` ラベル
- `cookbooks/claude-code/default.rb` の skills リストに登録
- 実行: `/loop <interval> /self-heal-create` (pro-dev インタラクティブ session)

検証: 初回実行で現状 open (21日経過 roon 含む) が issue 化 → メール着信確認 →
再実行で dup 0。

## Phase 2 — SNS 削除

setup repo (PR):
- `cookbooks/self-heal-observer/files/self-heal-observer.sh`:
  `sns_init`/`sns_publish`/`SNS_ARN` と 3 publish 箇所 (NEW/baseline/RESOLVED) を除去。
  ES state 書込・遷移ロジック・textfile は維持。cycle log の `sns=` を削除。
- `SELF_HEAL_SNS_ARN_SSM` 等の env を default.rb / observer.env から除去。
- header コメント更新 ("SNS notifier" → "ES alert reader")。
- dry-run + `bin/lint-cookbooks` + CI。auto-mitamae で CT111 適用。

home-monitor (CodeCommit, profile sh1admn):
- #96 を revert: `/monitoring/self-heal/sns-topic-arn` param + `sns:Publish` grant +
  `ssm:GetParameter /monitoring/self-heal/*` を削除。
- **`home-monitoring-alerts` topic 自体は既存・他用途で再利用なので触らない**。
- `terraform plan` → param destroy + policy in-place。user-gated apply。

順序: Phase 1 で issue 化が動くことを確認してから Phase 2 (通知ギャップを作らない)。

## Phase 3 — Loop B (resolve, 完全自律) ※安全柵込み

設置物 (setup repo):
- `cookbooks/claude-code/files/skills/self-heal-resolve/SKILL.md`
- `cookbooks/claude-code/default.rb` 登録
- 実行: `/loop <interval> /self-heal-resolve`

手順 (skill prompt):
1. open self-heal issue を 1 件選択 (古い順 / 着手 marker 無し) → "🔧 着手" comment
2. body の dedup_key/source/reason から調査 (uptime=host/svc down, es-query=Process down)
3. fleet probe (ssh/pct exec/systemctl/logs/elastic-agent status) で root cause
4. **remediation class 判定**:
   - allowlist 内 (crashed systemd service 再起動相当の cookbook 修正 / mitamae drift 再適用)
     → 自律続行
   - allowlist 外 (新規設計・破壊的変更・不明) → propose-only: PR 作成 + `self-heal-needs-human`
     ラベル + comment、issue は open のまま停止
5. branch → cookbook 修正 → `bin/lint-cookbooks` + mitamae-validator dry-run → PR
6. `gh pr checks --watch` green を待つ (red は merge しない)
7. merge → auto-mitamae が canary→fleet 適用 (既存 canary gate が fleet 保護)
8. **機能状態**で検証 (artifact でなく: ES doc-count 進行 / `elastic-agent status` HEALTHY /
   対象 service の機能 probe)。self-heal-state の当該 dedup_key が resolved に転じることを確認
9. resolved 確認 → issue close (原因/変更/PR/検証エビデンス comment)。
   3 回試行しても同一症状なら停止 → `self-heal-needs-human` + comment

安全柵 (完全自律でも必須):
- CI green まで merge しない / 破壊的操作 (delete・reset・force-push) 禁止
- 1 issue ずつ (fleet 同時変更を避ける)
- auto-mitamae canary gate が fleet 全体への誤適用を 1 段で止める
- fix-loop escalation: 3 試行で設計前提を疑い停止
- 初回は **インタラクティブに roon issue で 1 件 e2e 検証**してから無人 /loop に載せる

## 検証コマンド (Claude 実行可)

- observer: `ruby -c` / `bash -n` / shellcheck / `bin/lint-cognee... lint-cookbooks` / dry-run
- Loop A: 1 回実行 → `gh issue list --label self-heal` が ES open と一致 / 再実行 dup 0
- Loop B: roon issue で e2e (実 fix → PR → merge → 適用 → 検証 → close)
- home-monitor: `terraform plan` (revert 後) clean

## ファイル一覧

setup:
- `cookbooks/self-heal-observer/files/self-heal-observer.sh` (改修: SNS 除去)
- `cookbooks/self-heal-observer/default.rb` (env 除去)
- `cookbooks/claude-code/files/skills/self-heal-create/SKILL.md` (新)
- `cookbooks/claude-code/files/skills/self-heal-resolve/SKILL.md` (新)
- `cookbooks/claude-code/default.rb` (skills 登録)

home-monitor (CodeCommit):
- self-heal SNS param + grant の revert (#96 の逆)
