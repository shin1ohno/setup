# ADR 0005 Implementation Overview

ADR 0005 (`docs/adr/0005-rtx-logs-loki-to-elasticsearch.md`) の実装手順マスター。Phase 0 (capacity probe) と Phase 2 (PVE host alerts) は完了済 (PR #228/#229/#231)。本ファイルは未着手の Phase 1a/1b/3a/3b/4/5/6/7 を 10 PR に分割して実装するための索引。

## Master plan

詳細プランは `~/.claude/plans/woolly-knitting-meerkat.md` (2026-05-08 user 承認済)。本ディレクトリの per-phase ファイルは、master plan の各 phase に対応する実装メモ。

## Phase Inventory

| Phase | Repo | 担当 branch | 担当 plan ファイル | 依存 |
|---|---|---|---|---|
| 1a | home-monitor | `feat/adr0005-phase1a-memory-shrink` | `phase-1a-memory-shrink.md` | — |
| 1b | home-monitor | `feat/adr0005-phase1b-tls-ssm-iam` | `phase-1b-tls-ssm-iam.md` | — (1a と並行可) |
| 3a | home-monitor | `feat/adr0005-phase3a-es-kibana-lxcs` | `phase-3a-lxc-create.md` | 1a + 1b |
| 3b | setup | `feat/adr0005-phase3b-es-kibana-cookbooks` | `phase-3b-cookbooks.md` | 3a |
| 4 | setup | `feat/adr0005-phase4-vector-dual-write` | `phase-4-vector-dual-write.md` | 3 |
| 5 | setup | `feat/adr0005-phase5-kibana-saved-objects` | `phase-5-kibana-saved-objects.md` | 4 |
| 7-s3-tf | home-monitor | `feat/adr0005-phase7-s3-snapshot` | `phase-7-s3-snapshot.md` | 3 (parallel with 5) |
| 7-s3-cb | setup | `feat/adr0005-phase7-s3-cookbook` | `phase-7-s3-snapshot.md` (共有) | 7-s3-tf |
| 6 | setup | `feat/adr0005-phase6-cutover-loki` | `phase-6-cutover.md` | 5 + 2 週間観察 + 7-s3 |
| 7-tls | setup | `feat/adr0005-phase7-http-tls` | `phase-7-http-tls.md` | 6 |

## Worktree Layout

```
~/ManagedProjects/setup/.claude/worktrees/
  adr0005-overview              ← feat/adr0005-impl-plan         (本ファイル + 後続の plan ファイル集約用)
  adr0005-phase3b               ← feat/adr0005-phase3b-es-kibana-cookbooks
  adr0005-phase4                ← feat/adr0005-phase4-vector-dual-write
  adr0005-phase5                ← feat/adr0005-phase5-kibana-saved-objects
  adr0005-phase6                ← feat/adr0005-phase6-cutover-loki
  adr0005-phase7-tls            ← feat/adr0005-phase7-http-tls
  adr0005-phase7-s3-cookbook    ← feat/adr0005-phase7-s3-cookbook

~/ManagedProjects/home-monitor/.claude/worktrees/
  adr0005-phase1a               ← feat/adr0005-phase1a-memory-shrink
  adr0005-phase1b               ← feat/adr0005-phase1b-tls-ssm-iam
  adr0005-phase3a               ← feat/adr0005-phase3a-es-kibana-lxcs
  adr0005-phase7-s3             ← feat/adr0005-phase7-s3-snapshot
```

全 worktree branch は `origin/main` (setup: 68efc22 / home-monitor: ca6bfd2) から作成。

## 他 Agent / 別セッション の継続方法

特定 phase の実装を引き継ぐには:

1. 該当 branch をチェックアウト or 該当 worktree に `cd`:
   ```bash
   cd ~/ManagedProjects/setup/.claude/worktrees/adr0005-phase<N>
   # または home-monitor 側
   cd ~/ManagedProjects/home-monitor/.claude/worktrees/adr0005-phase<N>
   ```
2. 該当 plan ファイル `docs/adr/0005-impl/phase-<N>-*.md` を読む (master plan の 該当 section も参照)
3. ADR 0005 本文 (`docs/adr/0005-rtx-logs-loki-to-elasticsearch.md`) で全体像を把握
4. Adversarial review findings (master plan §Pre-implementation reviews) で blocker / risk を確認
5. 実装 → commit → push → PR open → CI green 後 merge → 依存 phase の apply に進む

## Critical Findings (Adversarial review 2026-05-08)

詳細は master plan §Pre-implementation reviews。特に注意すべき blocker:

- **#3, #15**: `lxc.cap.keep: ipc_lock` は bpg/proxmox provider 未対応見込み。Phase 3a 着手前に PVE host で probe 必須、未対応なら raw-config 編集 + `lifecycle.ignore_changes = [features]`
- **#1**: pve-bootstrap-ssm IAM の self-rotate 非対称性。`/monitoring/elastic/*` runtime fetch は OK、cookbook drift detection で password rotate 追従
- **#4**: X8 USB SSD SPOF + replica1 = HA 名目のみ。Phase 7-s3 を Phase 5 観察期間中に並行 apply で cutover 前に backup ready 化

## Apply ordering

```
Phase 1a apply → 1a verify
↓
Phase 1b apply → 1b verify
↓
Phase 3a manual probe + pct create + import → 3a verify
↓
Phase 3b mitamae apply (es-0 → es-1 → es-2 → kibana sequential) → cluster green verify
↓
Phase 4 mitamae apply (CT 111) → ES + Loki 同時投入 verify
↓
Phase 5 mitamae apply (CT 115) + saved-objects import → ブラウザ verify
↓ ↘
↓   Phase 7-s3-tf terraform apply → 7-s3-cb mitamae apply → snapshot test (parallel with observation)
↓
2 週間観察 (SLO 監視)
↓
Phase 6 mitamae apply (Loki 廃止 cutover)
↓
Phase 7-tls mitamae apply (HTTPS rolling、3 ノード sequential)
```

## TODO.md handoff items

- `pro-dev (CT 104) memory shrink reboot pending`: Phase 1a apply 後、CT 104 config は memory=8192 に更新済だが、運用中メモリ反映には reboot 必須。本 agent は CT 104 上で動作中のため self-suicide 回避、ユーザーが任意時刻に PVE host から `ssh root@192.168.1.10 'pct reboot 104'` 実施
- 2 週間観察期間 SLO チェック: ES query latency p95 < 500ms / cluster green 維持率 > 99% / Vector dual-write divergence < 1%
- Phase 7-s3 完了後の初回 restore drill (任意、~3 ヶ月後評価)

## Origin

このファイル群は 2026-05-08 セッションで Claude Opus 4.7 (1M context) が自律実装した ADR 0005 の trace。各 phase の実装詳細・実機確認結果・findings は per-phase plan ファイルに記録される。
