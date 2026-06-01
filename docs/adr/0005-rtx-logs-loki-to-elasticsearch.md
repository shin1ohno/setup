# ADR 0005: RTX log analytics — Loki + Vector → Elasticsearch + Kibana 移行

**Status**: Proposed (2026-05-08、Phase 0 capacity probe + Phase 2 alert 完了、Phase 1 以降の実装は未着手)

## Context

`lxc-monitoring` (CT 111) で運用中の Vector → Loki + Grafana 構成は、RTX1210 / RTX830 syslog の高カーディナリティ field 集計 (`sum by(src)` / `sum by(dst_port)` / Top-N) で重い:

| Range | Loki exec time | scanned | 備考 |
|---|---|---|---|
| 5m | 561 ms | 167k lines / 56 MB | snappy |
| 15m | 6-7 秒 | 2.24M lines / 629 MB | dashboard default、遅い |
| 1h | 11 秒 | 4M lines / 1.2 GB | 実用域外 |

原因は Loki のアーキテクチャ: label index しか持たず、`src` / `dst_port` / `geoip_*` 等の structured metadata は **chunk 全件 scan + パース** でないと集計できない。`max_query_series` の引き上げ、retention 短縮、recording rules、Vector 側の log 削減等を検討:

- **Loki recording rules**: top-N 集計を pre-compute するアプローチ。だが (a) `topk` は瞬時値演算子で recording 不可、(b) 全 series を保存すると Prometheus 側で同等の cardinality 爆発が再現、(c) flexibility (新 dimension 追加) が失われる、で却下
- **Vector で log 削減**: `filter_no=80` (WAN inbound default-pass、ノイズ大半) の drop 等。効果は大きいが、"WAN scan の生 evidence" を捨てる方針判断が必要、別軸の議論

dashboard の重さ問題と独立して、現構成は RTX 以外のログソース (将来の他 LXC syslog、journal、application log) を analytics する素地としても弱い。Loki の `| logfmt` / `| json` / `| line_format` は ES `match_only_text` + Lens の柔軟性に劣る。

検討した代替: ELK (= Elasticsearch + Kibana)、OpenSearch、ClickHouse + Vector、VictoriaLogs。最終的にユーザの `OpenSearch は機能に不安`、`本家の ES/Kibana で` の指示で **Elasticsearch 8.x 公式 + Kibana** を採用方針。

## Decision

**Vector → Elasticsearch (3-node HA cluster) + Kibana に移行する**。Loki は dual-write 期間 (Phase 4 移行猶予 2 週間) を経て廃止。

### 構成

| CT | Role | vCPU | RAM | Disk path | Disk size | Heap |
|---|---|---|---|---|---|---|
| 111 (monitoring) | Prometheus + Grafana + Vector + 各 exporter | 既存 | 既存 | rpool | 既存 | — |
| 112 (es-0) | ES master+data+ingest | 4 | **10 GB** | `/mnt/data/elasticsearch/es-0` (Crucial X8 USB) | 200 GB | **-Xms5g -Xmx5g** |
| 113 (es-1) | ES master+data+ingest | 4 | **10 GB** | `/mnt/data/elasticsearch/es-1` | 200 GB | **-Xms5g -Xmx5g** |
| 114 (es-2) | ES master+data+ingest | 4 | **10 GB** | `/mnt/data/elasticsearch/es-2` | 200 GB | **-Xms5g -Xmx5g** |
| 115 (kibana) | Kibana | 2 | 4 GB | `/data/kibana` (rpool) | 50 GB | NODE_OPTIONS=--max-old-space-size=1536 |
| **追加合計** |  | **14** | **34 GB** | — | **600 GB on USB X8 + 50 GB rpool** | — |

ES per-node 10 GB の内訳: heap 5 GB (locked、`bootstrap.memory_lock=true`) + JVM overhead 1 GB + OS file cache 4 GB。OS cache 4 GB/node は Loki 当初 Vector 移行で観測した 80 GB/node hot index に対し ~5% カバー、最新 backing index の hot 部分は十分に乗る。query 性能は当初設計の 8 GB 案より +25% 程度の見込み (cache hit ratio 改善)。

### Sizing 根拠 (Prometheus 実測 2026-05-08)

24h 実利用率を probe した結果、既存 LXC は alloc 34.5 GB に対し **real max 12.72 GB / avg 7.92 GB (= 稼働率 37% avg)** で大幅にダブついていた。特に `weave` (CT 109) は 5% 利用で 4 GB 確保、`pro-dev` (CT 104) は 43% 利用で 12 GB 確保。

実利用 max × 1.5 を新 alloc 目安として 7 LXC を shrink:

| CT | role | 旧 alloc | 24h max | 新 alloc | save |
|---|---|---|---|---|---|
| 100 | roon | 4.0 GB | 1.47 GB | 2.5 GB | 1.5 GB |
| 103 | housekeeping | 0.5 GB | 0.10 GB | 0.25 GB | 0.25 GB |
| 104 | pro-dev | 12.0 GB | 5.19 GB | 8.0 GB | 4.0 GB |
| 105 | cognee | 8.0 GB | 3.46 GB | 5.0 GB | 3.0 GB |
| 106 | hydra | 1.0 GB | 0.13 GB | 0.5 GB | 0.5 GB |
| 108 | roon-mcp | 1.0 GB | 0.27 GB | 0.5 GB | 0.5 GB |
| 109 | weave | 4.0 GB | 0.22 GB | 1.0 GB | 3.0 GB |
| **合計** |  |  |  |  | **12.75 GB save** |

shrink 適用後の budget:

| 資源 | 既存 LXC alloc (shrink 後) | 新規追加 | 合計 / host 上限 | 消費率 |
|---|---|---|---|---|
| RAM | **21.75 GB** | 34 GB | 55.75 / 62.8 GB | **89% (alloc-sum、real 見込み ~54 GB worst case / 38 GB best)** |
| vCPU | 25 (既存 overcommit 維持) | 14 | 39 / 12 cores | 3.25x (LXC idle 主体、PveHostCpuUsageHigh で実 CPU を監視) |
| Disk rpool | 90 GB | 50 GB | 140 / 928 GB | 15% |
| Disk /mnt/data (X8) | 486 GB | 600 GB | 1086 / 1815 GB | 60% |

Phase 1 (TLS/SSM/IAM 拡張) 着手前に Phase 0 として:

- ✓ `sda-backup-20260501.img` (932 GB) を /mnt/data から削除 (2026-05-08 実施済、1.3 TB free 確保)
- 未着手: 既存 7 LXC の memory shrink (`pve-lxcs.tf` の `memory =` 編集 + `terraform apply` + 順次 reboot)

shrink は ES cluster 構築前に実施することで、ES sizing 確定時の alloc-budget を確実に確保する。

### Storage 配置の選択 (fio ベンチ済)

ES storage は内蔵 NVMe-class (rpool/Apple SSD) ではなく外付け USB SSD (Crucial X8) 配置。判断材料は fio (PVE host) ベンチ:

| 指標 | rpool (Apple SSD/ZFS) | /mnt/data (X8 USB) | 選択理由 |
|---|---|---|---|
| Rand read 4K Q32 | 1,004 IOPS | **4,996 IOPS** | ZFS recordsize 128K の block amplification で rpool 不利。ES query path で 5x 速い |
| Sync write 4K fsync=1 | 584 IOPS | 137 IOPS | rpool 有利だが ES 要求 (1 fsync/sec) に対し X8 は 137 倍、十分 |
| Seq write 1M | 186 MB/s | 42 MB/s | ES 想定 sustained 2 MB/s に対し X8 で 20 倍ヘッドルーム |

USB SSD の物理的脆弱性 (ケーブル抜けで 3 ノード同時 disk loss) は ES HA の保護対象外、Phase 5 で S3 snapshot による補完。

### Cluster トポロジ

- 3 ノード全て combined role (`master, data, ingest`)
- `discovery.seed_hosts` + `cluster.initial_master_nodes` で静的 discovery
- `bootstrap.memory_lock: true` (LXC config に `lxc.cap.keep: ipc_lock` 必要)
- `number_of_shards: 1` / `number_of_replicas: 1` (1 ノード障害許容)
- transport TLS 必須 (CA + node certs を Terraform `tls_*` provider で生成、SSM SecureString 配布)、HTTP は LAN HTTP + basic auth (Phase 6 で TLS 化検討)

### Index 設計

- Data stream `logs-rtx-default` (composable templates: `logs-rtx-mappings` + `logs-rtx-settings`)
- `dynamic: "strict"` で schema drift 即検知
- Mapping: `src`/`dst`/`peer`/`local`/`lease_ip` を `ip` 型、`*_port` を `integer`、`message`/`ike_event` を `match_only_text`、`geoip_location` を `geo_point`
- Synthetic `_source` mode で disk -40%、`codec: best_compression` (zstd) で更に -30%
- ILM `logs-rtx-7d`: hot phase (`max_age: 1d`/`max_primary_shard_size: 10gb` で daily rollover) → 7 日経過で delete

### 認証

ES 8.x security plugin で 5 ロール: `elastic` (built-in superuser, 緊急復旧), `kibana_system` (built-in, Kibana → ES), `vector_writer` (`monitor` + `write` on `logs-rtx-*`), `grafana_reader` (任意), `rtx_analyst` (Kibana login + Discover/Visualize/Dashboard). 全 password を Terraform `random_password` 生成、SSM SecureString `/monitoring/elastic/{elastic,kibana,vector,grafana,analyst,monitor}-password` に格納、`pve-bootstrap-ssm` IAM policy 拡張で read 権限付与。

### 移行フェーズ

| Phase | Scope | PR 数 | 状態 |
|---|---|---|---|
| 0 | PVE host capacity probe + sda image 削除 + 24h 実利用率 probe | 0 (調査) | **完了 (2026-05-08)** |
| 2 | PVE host capacity Prometheus alert 12 件 (`pve-host.yml`) | 2 (#228, #229) | **完了 (2026-05-08)** |
| 1a | 既存 7 LXC の memory shrink (`pve-lxcs.tf` 編集 + apply + 順次 reboot)、12.75 GB の alloc-budget を解放 | 1 | 未着手 |
| 1b | TLS / SSM password / IAM 拡張 (home-monitor terraform) | 1 | 未着手 |
| 3 | ES cluster 構築 (home-monitor: pve-lxcs.tf に 4 CT / setup: lxc-elasticsearch + lxc-kibana cookbook 新規) | 2 | 未着手 |
| 4 | Vector dual-write (Loki + ES) + VRL に geo_point / port integer 化 | 1 | 未着手 |
| 5 | Kibana saved objects (dashboard / Lens visualization / Discover saved search / Maps) | 1 | 未着手 |
| 6 | Cutover (Grafana の Loki dashboard を hidden、2 週間運用観察、Loki sink + container 廃止) | 1 | 未着手 |
| 7 (任意) | HTTP TLS + S3 snapshot policy | 2 (#303, #307) | **完了 (2026-05-12)** |

各 Phase は独立して merge / rollback 可能。Phase 4 cutover まで Loki と ES に二重保持されるため、移行中のデータ loss なし。

## Consequences

### 採用の結果

- **集計性能**: `sum by(src)` 等の terms aggregation が ES 側で doc_values 列指向 store から 100ms オーダーで返却。Loki の 6-7s から ~50x 改善見込み
- **HA**: 3-node cluster + replica 1 で 1 ノード障害許容。LXC reboot / cookbook apply の ローリング対応可
- **検索 UI 強化**: Kibana Discover (full-text + filter)、Lens (visualization)、Maps (geo_point native)。ad-hoc 分析の表現力が Grafana + Loki LogQL より広い
- **schema validation**: data stream + `dynamic: "strict"` で field の drift 検知が ingest 時に発火 (Loki は label drift も silent)
- **既存 Vector / VRL を流用**: parse transform の regex 4 段 + GeoIP enrichment は変更不要、sink endpoint と一部 field 形 (geo_point / integer) のみ追加

### 否定面

- **リソース消費増**: RAM +34 GB (Phase 1a shrink で 12.75 GB 解放後、alloc-sum で host 89%、real 見込み 38-54 GB)、vCPU +14、disk 600 GB on USB X8。alloc-budget 残 7 GB で他大物 LXC を追加する余地は限定的
- **運用コスト増**: ES 3 ノードのローリング restart、TLS 証明書ローテーション (Terraform validity = 2 年、再生成 + SSM 配布 + cookbook 経由再 import の手順)、cluster red/yellow 監視。単一 Loki container と比較すると operational burden が大きい
- **disk SPOF**: 3 ES ノード全て同一 USB SSD (Crucial X8) に bind-mount。物理 disk failure / USB 抜けで全データ同時 loss。Phase 7 の S3 snapshot で補完するが、最初の 1 ヶ月程度は backup ない期間がある
- **license**: Elastic 公式 8.x は Elastic License v2 + AGPL v3 dual license。self-host personal use は Basic tier (security / ILM / alerting / Lens 含む) 無料、商用再配布は要 Elastic Subscription。本構成は personal use のため Basic で問題ないが、将来の運用形態変更時は再評価
- **Loki / Grafana 配線の整理**: `lxc-monitoring` cookbook の loki / grafana datasource / dashboards は Phase 6 で部分削除。Promtail からの移行 (PR #208-#215) で更新したばかりの relabel / regex / GeoIP 設定が Vector ES sink + Kibana 側で再現される (相当の logical 重複だが、Phase 4 dual-write 期間で動作確認は容易)
- **dashboard 移植コスト**: rtx-logs.json (Grafana) の 4 + 補助 panels を Kibana saved objects (NDJSON) に書き換え。1 人日程度

### 未決事項 (実装フェーズで判断)

- Kibana を Grafana のサブとして併用するか、log 分析の primary UI に格上げするか (運用習慣の問題)
- Retention 7 日で十分か、14 日に伸ばすか (disk 余裕次第、現 1.3 TB free / 600 GB 使用 → 14 日でも余裕あり)
- HTTP TLS の優先度 (LAN-only なら遅らせて OK、Tailscale 経由公開する場合は Phase 7 即実施)
- Vector の `buffer.type` (現 `memory` → 再起動で in-flight 喪失。`disk` + bind-mount に切替するか)

## References

- 関連 PR (Loki + Promtail → Vector 移行、本 ADR の前提整備): #208 / #209 / #210 / #211 / #212 / #213 / #214 / #215 / #221
- 関連 PR (PVE capacity alert): #228 / #229
- ベンチ結果原文: 2026-05-08 PVE host fio (rpool / X8 / X6 各 3 種類 workload)
- 容量実測: Prometheus query (`pve_memory_*`, `pve_cpu_usage_*`, `node_filesystem_*` on `192.168.1.10:9100`)
