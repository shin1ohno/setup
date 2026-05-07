# ADR 0002: Third Repository (`home-identity` / `home-registry`) Rejected

**Status**: Accepted (2026-05-07)
**Decision date**: 2026-05-07 (Phase A round-table session, supersedes the proposal made by Software Architect Round 1)

## Context

ADR 0001 でモノレポ化を却下した後、ソフトウェアアーキテクトが Phase A round-table Round 1 で「Identity & Access (host registry + IAM 定義 + Tailscale ACL + SSH 鍵 SSM 定義) を新規 `home-identity` リポに切り出し、両リポは読み取り専用依存とする」案を提示。

提案理由:
- Bounded Context として `Identity & Access` が現状 home-monitor / setup 両リポにまたがって漏れている
- Cohesion を 100% に戻し、二重更新を構造的に消す

## Decision

**コード (Ruby helper / Terraform module) を含む第 3 リポは却下**。提案者本人が Round 1 内で「JSON データのみの git submodule (`home-registry`)」に大幅縮退、最終的に ADR 0004 の SSM 配送方式に統合された。

## Consequences

### 却下の結果

- リポジトリ数を 2 のままに維持: Claude Code セッションでの multi-repo 認知負荷増 (`git -C` 取り違え事故、setup PR #156/#158 で実証済み) が回避される
- IAM 発行権限 (Terraform state) と cookbook write 権限 (LXC RCE 等価) の write boundary 分離が保たれる
- `home-identity` を作る場合に必要だった「3 リポ間の release ordering」「各 consumer (home-monitor / setup) の依存方向管理」運用が不要

### 否定面 (放置されるコスト)

- "Identity & Access" Bounded Context の物理的漏れは残る → ADR 0004 の SSM 契約型付けで論理的に統合

## Alternatives Considered

### コード含む第 3 リポ抽出 (`home-identity`) — 却下

**セキュリティ専門家 Round 1 評価**: 典型的な privilege aggregation anti-pattern。Identity 関連変更の write 権限 (IAM principal 定義 + devices.json + Tailscale ACL) が単一 GitHub repo write permission に集約されると:

1. `home-identity` への push 権限保有者は IAM principal 新規作成 / credential SSM 投入 / cookbook 経由 LXC 展開 を 1 PR で実行可能
2. 現状 3 ステップ別々のリポ権限が必要なのが 1 ステップに圧縮される
3. CloudTrail correlation の audit trail 起点が分散

**SRE 専門家 Round 1 評価**: PR 数を減らさず、新 LXC 追加で 3 リポを順序付き touch する必要が残る。MTTR 試算で災害復旧時に復旧対象 state を増やすだけで現状より +15-20 分悪化。

**Devil's Advocate Round 1**: "中途半端な統合 = 最悪の世界" シナリオ — semver 文化が薄い mitamae cookbook + Terraform HCL では breaking change を CI 側に依存、半年後に shared リポの最新を誰も読まなくなり setup 側で直書きされフォーク状態に陥る。

**個人開発者 Round 1**: "半年後の自分シナリオ" で 3 リポ目を clone する記憶コストが追加。

### データのみ git submodule — 却下 (提案者の縮退案、最終的に SSM 配送に統合)

提案者 (アーキテクト) が Round 1 で「JSON データのみ + コードなし + バージョニングなし + submodule SHA pin」に縮退。setup PR #189 で実装試行 → CI 認証で詰まる (cross-VCS submodule auth) → close。

## References

- ADR 0001: モノレポ却下 (補完関係)
- ADR 0004: 最終的な SSM 配送方式
- 円卓会議セッション: 2026-05-07 (Round 1 + Round 2、`~/.claude/plans/replicated-sleeping-manatee.md` 参照)
- 廃案実装: setup PR #189 (closed)
