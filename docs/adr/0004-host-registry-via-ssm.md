# ADR 0004: Host Registry Distribution via AWS SSM Parameter Store

**Status**: Accepted (2026-05-07、Phase A 実装完了)

## Context

ADR 0001 / 0002 で「2 リポ分割を維持、コード含む第 3 リポも却下」と決定したが、両リポにまたがる暗黙契約 (host registry: hostname → SSH key SSM path / IAM principal / LXC spec) が事故源として残る。Phase A round-table 2026-05-07 で配送方式を再検討。

最初の試行 (round-table 直後): `home-monitor/contracts/devices.json` を git source-of-truth にし、setup から git submodule で読む。setup PR #189 で実装試行。

実装で発覚した問題:
- CodeCommit ↔ GitHub の cross-VCS submodule 認証 (CI runner で `git-remote-codecommit` + AWS OIDC + `protocol.codecommit.allow=always` が必要)
- submodule SHA pin の手動運用負担
- broken symlink (CI で submodule 未初期化時に cookbook が file 不在で fail)

## Decision

**Host registry の配送経路として AWS SSM Parameter Store `/host-registry/devices` を採用する**。submodule 案は廃案。

具体実装:

```
home-monitor (CodeCommit)            AWS SSM                    setup (GitHub)
─────────────────────────            ───────                    ──────────────
contracts/devices.json   ─Terraform→ /host-registry/devices ──┬─ mitamae cookbook (pve-bootstrap-ssm)
(git source of truth)                (jsonencode minified)    └─ GitHub Actions CI (setup_ci_ssm_reader OIDC)
```

- `home-monitor/contracts/devices.json`: git で source 管理 (19 entries: 5 hosts + 12 LXCs + 2 iOS clients)、`contracts/devices.schema.json` で型制約
- `home-monitor/host-registry-ssm.tf`: `aws_ssm_parameter.host_registry_devices` で SSM 投入 (jsonencode で minify、Advanced tier、現在 5987 bytes)
- `setup/cookbooks/ssh-keys/files/aws-config.json`: bootstrap minimal config (aws_profile + aws_region のみ)、SSM 接続用
- `setup/cookbooks/ssh-keys/default.rb`: `aws ssm get-parameter --name /host-registry/devices` で fetch
- `home-monitor/setup-ci-oidc.tf`: GitHub OIDC + `setup_ci_ssm_reader` IAM role
- `setup/.github/workflows/test-setup.yml` `ssm-validation` job: CI で OIDC role assume + SSM fetch + jq sanity check

## Consequences

### 採用の結果

- **認証経路統一**: AWS IAM 1 本 (mitamae 用 `pve-bootstrap-ssm` + CI 用 `setup_ci_ssm_reader`)。cross-VCS submodule auth (CodeCommit ↔ GitHub) が不要
- **VCS 中立**: setup (GitHub) と home-monitor (CodeCommit) の差異が消える。将来 home-monitor を GitHub に移しても影響なし
- **既存パターン流用**: `aws ssm get-parameter` は cookbook の既存 `fetch_ssm` lambda と同じ form
- **バージョニング**: SSM Parameter Version (100 履歴) + git source (`contracts/devices.json`) で二重管理
- **CI で構造的整合性検証**: `ssm-validation` job が PR ごとに走る (kind enum / ssm_prefix pattern / reserved namespace deny / lxc.* required / ios-client.client_only=true / aws-config.json drift)

### 否定面

- **SSM Advanced tier コスト**: $0.05/parameter/month (現在 1 個のみ)。devices.json サイズが 8KB 上限に近づいたら parameter 分割が必要
- **AJV による厳密 schema validation は未実装**: schema を setup repo に copy すると drift 再導入、home-monitor から CI で fetch すると cross-VCS auth 復活。jq sanity check で代替したが、edge case の検出は schema validation より弱い (将来改善余地)
- **SSM 不在時のフォールバックなし**: AWS SSM が一時的に unavailable な場合、cookbook は graceful WARN+return で skip (致命的ではないが、apply の冪等性が損なわれる時間帯がある)

### 不変条件 (Phase B/C で破ってはいけない)

1. `contracts/devices.json` の git source は home-monitor 側に維持 (setup ではない)
2. SSM への投入は Terraform 経由のみ。手動 `aws ssm put-parameter` で書き込まない (drift 発生)
3. `pve-bootstrap-ssm` の policy は `/host-registry/devices` + `/ssh-keys/devices/*` の read のみ。put 系は追加しない (ADR 0003 unbroken condition #3)

## Alternatives Considered

### Submodule 経由配送 (`external/home-monitor`) — 廃案

setup PR #189 で実装試行、CI で `git submodule update --init` が cross-VCS auth + protocol.codecommit.allow=always 不在で fail → close。

### GitHub raw URL で fetch — 検討せず却下

home-monitor が CodeCommit のため raw URL は AWS GovCloud/CN 系 region では HTTPS 認証が必要。setup を `setup-ci-oidc` 同等で fetch するなら結局 OIDC 経路が要る。SSM 経由と認証経路の本質は変わらないが、SSM の方が cookbook の既存 `fetch_ssm` パターンと整合する。

### Terraform output → JSON commit + cross-repo PR bot — 検討せず却下

home-monitor で `terraform output > contracts/devices.json` を生成して setup repo に PR bot で sync する案。home-monitor が CodeCommit (GitHub Actions なし) のため bot 実装に追加 infra が必要。複雑度に対して SSM 案より利益が小さい。

### モノレポ / 第 3 リポ — 却下

ADR 0001 / 0002 参照。

## References

- ADR 0001 (monorepo rejected)
- ADR 0002 (third repo rejected)
- ADR 0003 (IAM trust boundary = repo boundary)
- 円卓会議: 2026-05-07 (`~/.claude/plans/replicated-sleeping-manatee.md` Phase A SSM 切替セクション)
- 廃案実装: setup PR #189 (closed)
- 採用実装:
  - home-monitor PR #27 (contracts/ + JSON Schema、merged)
  - home-monitor PR #28 (jsondecode wire-up、merged)
  - home-monitor PR #30 (SSM parameter + IAM OIDC role、merged + applied)
  - setup PR #191 (cookbook SSM fetch 化、merged)
  - setup PR #192 (CI workflow に ssm-validation job、merged)
