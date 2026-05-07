# ADR 0001: Monorepo Consolidation Rejected

**Status**: Accepted (2026-05-07)
**Decision date**: 2026-05-07 (Phase A round-table session)

## Context

`home-monitor` (Terraform IaC, CodeCommit) と `setup` (mitamae cookbook, GitHub) の 2 リポジトリ運用について、円卓会議 (専門家 5 名 + Devil's Advocate 2 ラウンド) で再評価を実施。モノレポ化 (両リポを 1 つに統合) を選択肢として検討。

評価背景:
- PR #142 (air hostname mismatch)、PR #166→#167 revert (pve-bootstrap-ssm self-rotation)、home-monitor PR #14 (reserved namespace) など、両リポにまたがる暗黙契約に起因する事故が複数発生
- "リポジトリ境界をどう引き直すか" の問いとして、モノレポ統合が候補に上がった

## Decision

**モノレポ化は却下する**。2 リポ分割を維持。

## Consequences

### 採用の結果 (2 リポ分割維持)

- IAM 信頼境界 = リポジトリ境界の整合が保たれる: home-monitor は AWS IAM CRUD (Terraform state に access key 平文保管)、setup は `aws ssm get-parameter` のみ。`terraform apply` 権限と LXC 上のコマンド実行権限が同一 GitHub repo write permission に集約されない
- Terraform / mitamae の異なる実行モデル (宣言 vs 命令的収束) が repository 単位で物理隔離される: PR レビューの認知モードが混在しない
- 変更頻度の差 (Terraform 月単位 / mitamae 週単位) が CI 時間に直結しない

### 否定面 (放置されるコスト)

- 跨ぎ変更 (新ホスト追加、認証情報ローテ、OS アップグレード) が複数 PR に分散: 推定 20-25% の変更が 2 PR を要する
- `bin/bootstrap-lxc-creds` のような cross-repo 認証情報配布スクリプトの手動オペレーションが残る (Phase B で orchestrator 統合予定)
- ホスト名 registry の cross-repo 暗黙契約が残る → ADR 0004 の SSM 配送方式で型付けして緩和

## Alternatives Considered

### 統合 (モノレポ化) — 却下

**Spotify Pants Build 撤退 (2018-2020)** の前例: マイクロサービス境界が過剰に細分化された結果 cross-repo PR が運用負荷の最大要因になり、モノレポへ回帰を試みたが Pants build system の維持コストで撤退。本ケースは規模 (ホスト数 ~15) と運用者数 (1 人) が Spotify と異なるが、教訓は「Bounded Context が物理的に正しくても、運用上の cross-cut が頻繁な領域を分離してはいけない」「ただし統合した場合のツールチェーン地獄は規模に依らず発生する」。

**HashiCorp Recommended Practices (2022 改訂版)** は「Identity & Access を独立リポに切り出すのは組織が 50+ engineer かつ Identity 専任チームがある場合のみ」と明記。本ケース (個人 1 名運用) は閾値の 1/50 以下。

統合 MTTR 試算 (SRE 専門家 Round 1):
- 現状 (PVE host 故障): 90-120 分
- モノレポ案: state ファイル統合により Terraform / mitamae の依存解決が肥大化、推定 +30 分以上悪化

### コード含む第 3 リポ抽出 — 却下

ADR 0002 参照。

## References

- 円卓会議セッション: 2026-05-07 (`~/.claude/plans/replicated-sleeping-manatee.md` 参照)
- Spotify Pants Build 撤退: <https://blog.pantsbuild.org/spotify-engineering-and-pants/> (2020-09 公開時点の参照)
- HashiCorp Recommended Practices: Terraform Multi-Account Strategy
