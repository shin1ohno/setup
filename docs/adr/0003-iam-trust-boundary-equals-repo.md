# ADR 0003: IAM Trust Boundary = Repository Boundary

**Status**: Accepted (2026-05-07)

## Context

ADR 0001 (モノレポ却下) と ADR 0002 (第 3 リポ却下) の判断基盤を明文化。なぜ `home-monitor` と `setup` を分離して維持するのか、その根拠を明示する。

## Decision

**`home-monitor` と `setup` のリポジトリ境界 = AWS IAM 信頼境界として扱う**。両リポは異なる IAM permission set の下で動作することを設計の前提とする。

具体的には:

- **`home-monitor`** (CodeCommit、AWS profile `sh1admn` = AdministratorAccess):
  - `aws_iam_user`, `aws_iam_role`, `aws_iam_policy` の CRUD 権限
  - `aws_kms_key` の管理権限
  - `aws_ssm_parameter` への putParameter (SecureString 含む)
  - `terraform.tfstate` に access key 平文保管 (S3 バックエンド KMS 暗号化)

- **`setup`** (GitHub、各デバイスは AWS profile `pve-bootstrap-ssm` = 限定権限):
  - `ssm:GetParameter` のみ (read-only)
  - scope: `/host-registry/devices` + `/ssh-keys/devices/*`
  - 自身の credential `/home-monitor/iam/pve-bootstrap-ssm/*` には到達不可 (self-rotation 防止)

## Consequences

### 採用の結果

- 両リポを統合する設計選択肢 (モノレポ、第 3 リポ) はこの境界を破壊するため自動的に却下される
- cookbook がコンプロマイズされても IAM 発行への上書き経路は AWS API レベルで遮断 (`pve-bootstrap-ssm` 権限の policy で deny)
- credential rotation の起点 (sh1admin の terraform apply) と consumer (各デバイスの mitamae) が物理的に分離

### 否定面

- cross-repo 暗黙契約 (devices.json schema、SSM パス命名、IAM principal 名) は引き続き存在 → ADR 0004 の SSM Parameter Store 経由配送 + jq sanity check で型付け

### 設計上の不変条件 (今後の変更で破ってはいけない)

1. `setup` の cookbook は `aws iam *`, `aws kms *`, `aws ssm put-parameter` を呼ばない
2. `home-monitor` の Terraform state は cookbook write 権限を持つ identity からは到達できない場所に保管 (S3 + IAM 制御)
3. `pve-bootstrap-ssm` IAM user の policy に `ssm:PutParameter` を追加する変更は **自動的に却下** (self-rotation 防止)
4. `setup_ci_ssm_reader` IAM role (GitHub OIDC) の permission を `ssm:GetParameter on /host-registry/devices` 以外に拡張する変更は明確な justification 必要

## Alternatives Considered

### 統合運用 (モノレポ) — 却下

ADR 0001 参照。IAM 信頼境界を破壊する。

### 第 3 リポ抽出 (`home-identity`) — 却下

ADR 0002 参照。`home-identity` への write 権限保有者が IAM 発行 + cookbook 展開を 1 PR で実行可能 = privilege aggregation。

## References

- ADR 0001 (monorepo rejected)
- ADR 0002 (third repo rejected)
- ADR 0004 (host registry distribution via SSM)
- `~/.claude/rules/aws-iam.md` "IAM principal that cannot self-rotate — design `bootstrap_profile` chain accordingly"
