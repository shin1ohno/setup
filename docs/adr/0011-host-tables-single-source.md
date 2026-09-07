# ADR 0011: ホスト台帳の一元化 — 設定表の不整合を CI で FAIL にし、台帳スナップショットからの生成へ進む

**Status**: Proposed (2026-09-07)

## Context

`docs/refactoring/2026-08-hurdle-removal.md` Stream C は「home-monitor の SSM 台帳（`/host-registry/devices`）
から版を識別できるスナップショットを作り、setup 側の表を生成する」計画だが、setup 側の
`bin/render-host-configs` とスナップショットは存在せず、次の 3 表が別々に手編集されている:

| 表 | 用途 | 件数（2026-09-07） |
|---|---|---|
| `cookbooks/auto-mitamae-orchestrator/files/hosts.json` | 自動適用の対象（forced-command で push） | 18 |
| `cookbooks/lxc-monitoring/files/prometheus.yml` の `node-*` job | node-exporter scrape | 17 → 19 |
| `cookbooks/host-profile/default.rb` の FLEET `ip` | オフラインのホスト identity（es-* の transport IP） | 3 |

静的照合で確認した不整合（本 ADR の `bin/check-host-configs` が修正前に 4 件を FAIL として出力）:

- 自動適用対象の dns-resolver（.61）・homebridge（.84）・es-memory（.83）に node-exporter の scrape job が無い。
- #616 で廃止された lxc-memory（CT 107、.72）の `node-memory` job が残っている。

`bin/lint-cookbooks` check 10 は hosts.json ↔ pve/*.rb ↔ FLEET を WARN で照合するが、Prometheus 側は
見ておらず、WARN は CI を落とさない。

**未検証範囲**: この作業ホストから AWS（profile `pve-bootstrap-ssm`）に到達できないため、SSM
`/host-registry/devices` の現行 schema と、上流 home-monitor PR #120（`ip` フィールド追加）の apply 状況は
確認していない。8/3 文書の「承認待ち」を現在の状態とは扱わない。スナップショット形式の確定は SSM を
読める環境での次の段とする。

## Decision

### 1. 3 表の不整合を FAIL にする検査を通常 CI に載せる（本 PR で実装）

`bin/check-host-configs`（Ruby、依存なし）が hosts.json・prometheus.yml の `node-*` static job・FLEET `ip`
を読み、(1) 適用対象で scrape されないホスト、(2) hosts.json に無いホストを scrape する job、(3) `host`
label と hosts.json label の不一致、(4) FLEET ip と hosts.json の不一致、(5) 適用されなくなった policy
エントリ、を FAIL にする。`syntax-check` job で実行する。

### 2. 意図的な除外・別名は `config/host-policy.json` に理由付きで明示する（本 PR で実装）

setup 固有のポリシー（監視のみのホスト、適用のみのホスト、node-exporter を置かないホスト、job 名の別名）
はこのファイルだけに書く。理由の無い除外は許さず、対象が消えた policy は (5) で FAIL する。初期内容は
`nrt-router`（AWS EC2、home-monitor 管理、auto-mitamae 対象外）のみ。ホストデータは持たない（台帳は SSM）。

### 3. prometheus.yml の drift を直す（本 PR で実装）

`node-memory` を削除し、`node-dns-resolver` / `node-homebridge` / `node-es-memory` を既存 job と同じ形
（`honor_labels: true`、`host` label = hosts.json label）で追加する。

### 次の段（本 PR の範囲外、順序付き）

1. SSM を読める環境で `/host-registry/devices` の現行 schema を読み、`contracts/hosts.snapshot.json`
   （SSM parameter の version と取得時刻を含む）の形式を確定する。取得は operator の明示操作
   （`bin/refresh-host-snapshot`）で、通常 apply は snapshot だけを読みオフラインで動く。
2. `bin/render-host-configs` が snapshot + `config/host-policy.json` から hosts.json と Prometheus の
   node-exporter target を生成する。Prometheus 側は per-host static job を `file_sd_configs` 1 job +
   生成 target ファイルに置き換える（Prometheus 標準機構。`host` label は target の labels で渡す）。
   `bin/check-host-configs` は「生成結果 == commit 済み」の diff 検査へ役割を変える。
3. host-profile FLEET の `ip` も同じ snapshot から導出する。

## Consequences

- ホスト追加・削除で 3 表のどれかを忘れると CI が落ちる。除外は理由付きで 1 か所。
- 生成器が無い間は手編集が続くが、不整合は commit 前に見える。
- `file_sd` 化までは Prometheus 設定は static job のまま（アラート・ダッシュボードの `host` label 契約は不変）。

## Rejected alternatives

- **lint check 10 の WARN を FAIL に格上げするだけ**: Prometheus 側を見ない。3 表の照合が必要。
- **SSM を CI から直接読む**: 通常 apply・CI に認証とネットワークの起動時依存を増やす。Stream C の方針
  （版付きローカルスナップショット）を維持。
- **今すぐ file_sd + 生成器を実装する**: snapshot 形式が SSM 未確認のまま確定してしまう。検査を先に置き、
  形式は SSM を読める環境で決める。
