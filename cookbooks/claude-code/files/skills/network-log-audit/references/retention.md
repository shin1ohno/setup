# どこまで遡れるか

保持期間の実測、n 日前に対する参照先の対応表、ILM が削る速度、S3 スナップショットからの復元手順。

as-of 2026-09-06。数値はすべて実測で、母数と窓を添えてある。
このファイルは `network-log-audit` skill の参照資料。実機は読み取りのみ。

---

## 2. どこまで遡れるか

### 2.1 保持期間の実測

| データストリーム | 実データ最古 (UTC) | 遡及 | ILM policy | delete min_age |
|---|---|---|---|---|
| `logs-wlx-default` | 2026-08-29T15:46:15Z | 7.51 d | `logs-wlx-7d` | 7d |
| `logs-rtx-default` | 2026-08-29T09:53:41Z | 7.75 d | `logs-rtx-7d` | 7d |
| `metrics-prometheus.collector-default` | 2026-08-05T05:33:39Z | 31.93 d | `metrics` | 30d |
| `traces-apm-default` | 2026-07-30T07:43:57Z | 37.84 d | `traces-apm.traces-default_policy` | 10d |
| `metrics-system.network-default` | 2026-07-11T01:53:04Z | 57.09 d | `metrics` | 30d |
| `synthetics-http-default` | 2026-05-10T08:37:01Z | 118.81 d | `synthetics-…http…_policy` | 365d |
| `synthetics-tcp-default` | 2026-05-10T08:37:01Z | 118.81 d | `synthetics-…tcp…_policy` | 365d |
| `logs-elastic_agent.heartbeat-default` | 2026-05-10T08:28:46Z | 118.81 d | `logs` | **なし** |
| `logs-system.journal-default` | 2026-05-02T17:27:10Z | 126.44 d | `logs` | **なし** |

`delete.min_age` の起点は index 作成時刻ではなく **rollover 時刻**。実効保持 = rollover 周期 + min_age。**`logs` ポリシーには delete フェーズが無く、7 日で消えるのは `logs-rtx-7d` / `logs-wlx-7d` を当てた 2 本だけ。**

**削れ方は連続ではなく 1 日 1 ステップ** — バッキングインデックス 1 本（約 24 時間分）が一括消滅する。ILM poll は `10m` 刻みなので削除時刻は毎日約 +10 分ずつ後ろへずれる。

| logs-rtx バッキングインデックス | rollover (UTC) | 削除 (UTC) |
|---|---|---|
| `.ds-logs-rtx-default-2026.08.29-000212` | 2026-08-30T10:03:41Z | **2026-09-06T10:03:41Z** |
| `…2026.08.30-000214` | 2026-08-31T10:13:41Z | 2026-09-07T10:13:41Z |
| `…2026.09.04-000224` | 2026-09-05T11:03:41Z | 2026-09-12T11:03:41Z |

| logs-wlx バッキングインデックス | rollover (UTC) | 削除 (UTC) |
|---|---|---|
| `.ds-logs-wlx-default-2026.08.29-000156` | 2026-08-30T15:53:41Z | **2026-09-06T15:53:41Z** |
| `…2026.08.30-000158` | 2026-08-31T16:03:41Z | 2026-09-07T16:03:41Z |
| `…2026.09.04-000168` | 2026-09-05T16:43:41Z | 2026-09-12T16:43:41Z |

ドリフトは rtx が正確に +10 分/日、wlx が平均 +8.3 分/日（1 日だけ +0 分）。**実効窓の幅は削除直後 7 日ちょうど、次の削除直前で 8 日強。「7 日保持」は下限。**

index 名の日付が中身の日付とほぼ一致するので、「いつのログか」は index 名で当たりを付けられる。

注: `logs-rtx-7d` は version 23654、`logs-wlx-7d` は version 16823 と大きいが、Terraform / auto-mitamae が同内容を繰り返し PUT しているだけで、ILM の実行状態はリセットされない。異常ではない。

### 2.2 「n 日前」→「どのソース」対応表

◎ = 一次ソース / ○ = 使える / △ = 条件付き / × = 無い

| 経過時間 | logs-rtx / logs-wlx | 機器内蔵 `show log` | S3 スナップショット | prometheus (SNMP/node) | synthetics | metrics-system.network | journal (pro) |
|---|---|---|---|---|---|---|---|
| **1 日以内** | ◎ 全文・構造化 | ○ ITM 7.7d / WLX323 7.5d、△ HND は 42 分 | 不要 | ○ 30s 粒度 | ○ | ○ | △ PVE のみ |
| **1〜7 日** | ◎（削除時刻に注意） | ○ ITM / WLX323、× HND | 不要 | ◎ | ○ | ○ | △ |
| **7〜14 日** | × 消滅済 | × | ◎ **要 restore・要承認** | ◎ 主力 | ○ | ○ | △ |
| **14〜21 日** | × | × | △ 最古 2026-08-16。1 日 1 本ずつ失効 | ◎ 主力（31.9 日） | ○ | ○（57 日） | △ |
| **21〜30 日** | × | × | × | ◎ **唯一の詳細ソース** | ○ | ○ | △ |
| **30 日〜** | × | × | × | × | ◎ **118.8 日（唯一）** | ○ 57 日 | △ 126 日、PVE のみ |

**判断フロー**

1. **まず窓を確定する**（§0 ①）。調査対象日が床の直上なら、先に restore の承認を取る（数時間で消える）。
2. **7 日以内は syslog を主、SNMP を裏取り。**ES の `@timestamp` は Vector 受信時刻なので装置時計ずれを考えずに他ソースと突き合わせられる。
3. **7 日を超えたら SNMP/Prometheus を主にする。**リンク断・AP 再起動・スイッチポート状態は `snmp-rtx` job で 30 日読める。`ifOperStatus` は enum ラベルで絞る（§5.2）。
4. **一斉断か個別断かは synthetics で決める。**有線 LXC の TCP monitor が同一 10 分バケットで複数同時に down なら LAN / スイッチ / PVE 側。
5. **30 日超は synthetics のみ。**到達性の up/down しか残らず、原因特定はできない。時間帯の絞り込みまで。
6. **Wi-Fi 固有の事象は 7.5 日を超えると事実上追えない。**WLX323 の内蔵ログもリングでラップする。`SWX2100-5PoE` のポート down（30 日）で AP の電源断・再起動だけは検出できるが、電波側（DFS / ローミング / 認証失敗）の証拠は残らない。

**7〜30 日を SNMP で見るときの主力クエリ**

```bash
# スイッチポートの down 区間（ifOperStatus は enum 3 系列。ラベルと値の両方で絞る）
echo '{"size":0,"query":{"bool":{"filter":[
  {"term":{"prometheus.labels.ifOperStatus":"down"}},
  {"term":{"prometheus.metrics.ifOperStatus":1}},
  {"prefix":{"prometheus.labels.ifDescr":"SWX"}},
  {"range":{"@timestamp":{"gte":"now-30d"}}}]}},
 "aggs":{"i":{"terms":{"field":"prometheus.labels.ifDescr","size":20},
   "aggs":{"t":{"date_histogram":{"field":"@timestamp","fixed_interval":"30m","min_doc_count":1}}}}}}' \
 | Q metrics-prometheus.collector-default
```

実測（直近 30 日、常時 down の未使用ポートを除く）:

| ifDescr | down サンプル数 | 日別内訳 | 換算（1 サンプル = 30 秒） |
|---|---|---|---|
| `SWX2100-5PoE_Z5101897WZ:1` | 129 | 08-23:1 / **08-29:126** / 09-05:2 | 08-29 に約 63 分 down |
| `SWX2100-5PoE_Z5101897WZ:4` | 10 | 08-17:5 / 08-23:1 / 08-29:2 / 09-05:2 | 各 1〜3 分 |
| `SWX2100-5PoE_Z5101897WZ:5` | 4 | 08-23:1 / 08-29:1 / 09-05:2 | 各 1 分 |
| `SWX2110P-8G_Z7K01199CX:6`,`:8` | 各 1 | 08-12 のみ | 30 秒 |

08-29 の `:1` の 63 分は WLX323 の boot time 実測 `2026/08/29 17:39:34 JST` と整合する（**この対応づけは状況証拠**。どのポートにどの AP がぶら下がるかは LAN マップで確定させる — §4.2）。

**判別ルール**: 08-23 / 08-29 / 09-05 のように複数ポートが同一タイムスタンプで同時 down なら、個別ポートのフラップではなく上位（スイッチ本体の再起動 / L2MS / SNMP 取得側）の事象。

**snmp-rtx で取れるメトリクス**: `ifInOctets` `ifOutOctets` `ifHCInOctets` `ifHCOutOctets` `ifInErrors` `ifOutErrors` `ifInDiscards` `ifOutDiscards` `ifSpeed` `ifHighSpeed` `ifAdminStatus` `ifOperStatus` + YAMAHA 私有 MIB `yrfUpTime`（再起動検出）`yrfRevision` `yrfFirmwareFile` `yrhCpuUtil{5sec,1min,5min}` `yrhMemoryUtil` `yrhInboxTemperature`。ラベルは `router`(hnd/itm) / `ifIndex` / `ifDescr` / `instance`。

`ifDescr` 実測（HND 35 種）: `LAN1` `LAN2` `LAN3` `WAN1` `BRI1` `BRIDGE1` `LOOPBACK1`〜`9` `NULL` `UNKNOWN`、**`SWX2100-5PoE_Z5101897WZ:1`〜`:5`**、**`SWX2110P-8G_Z7K01199CX:1`〜`:8`**、**`RTX830_M5B102332:1`〜`:5`**。ITM は 14 種。**配下スイッチの毎ポート帯域・エラー・discard が RTX 経由で取れる**（SWX は自前 syslog を出さない）。

その他の job: `node-*` 16 本（`node_network_*` 36 種、`node_nf_conntrack_*` 10 種、`node_network_carrier_changes_total` で LXC/PVE の物理リンクフラップ）、`pve`（ゲスト単位 `pve_network_receive_bytes` 等 20 種）、`mcp-blackbox-*`、`prometheus`、textfile の `auto_mitamae_*`。

`up{job="snmp-rtx"}` は直近 30 日で `up=0` が 208 サンプル（`up=1` は 172,556）= RTX が SNMP に応答しなかった窓の代替指標。

**metrics-system.network-default**: ホスト 18 台（`pro` `monitoring` `weave` `consent` `roon-mcp` `pro-dev` `es-0` `es-1` `es-2` `kibana` `pro-router` `dns-resolver` `homebridge` `housekeeping` `hydra` `samba` `es-memory` `roon`）。インタフェース名 `veth100i0`〜`veth120i0` が **CT ID と対応**するので PVE ホスト側から LXC 単位のトラフィックが見える。

**30 日超は synthetics のみ** — probe の発信元は全て `agent.name=monitoring`（CT111 = .76、有線 LXC）。**すべての probe は有線経路で Wi-Fi 区間を通らない。**Wi-Fi 経路を通りうる probe は `Eternal Terminal mini TCP 2022` の 1 本だけだが、down 率 69.2%（70,508/101,880）で Mac のスリープと ET プロセスの有無が支配的 — **Wi-Fi 健全性の指標には使えない**（有線対照の `pro-dev` は down 10/101,880 = 0.01%）。

### 2.3 S3 スナップショットからの復元

`GET _snapshot/s3-home-monitor/_all` 実測: **14 本、全て `SUCCESS`、`shards.failed=0`、2026-08-24 〜 2026-09-06**。

- repository: `s3-home-monitor` (type=s3, bucket=`home-monitor-elasticsearch-snapshots-384858471975`, base_path=`snapshots/home-monitor-rtx`, compress=true)
- SLM policy `daily-snapshot`: schedule `0 30 1 * * ?` = **01:30 UTC（10:30 JST）**、retention `expire_after=14d` / `min_count=7` / `max_count=14`
- 累計 taken=115 / failed=3 / deleted=103、`retention_failed=0`
- 対象 indices: `logs-*` `synthetics-*` `traces-*` `self-heal-state` `memory-{fact,knowledge,episode,stats}`、`include_global_state=true`

**各スナップショットが含む最古のバッキングインデックス**

| snapshot | start (UTC) | logs-wlx 最古 | logs-rtx 最古 |
|---|---|---|---|
| `daily-snap-2026.08.24-xo5lvackq7kem0hywpg3ha` | 08-24T01:29:59Z | `.ds-logs-wlx-default-2026.08.16-000128` | `.ds-logs-rtx-default-2026.08.16-000186` |
| `daily-snap-2026.08.25-y-b-a91yr_cmofj6hwlnog` | 08-25T01:29:59Z | `…2026.08.17-000131` | `…2026.08.17-000188` |
| `daily-snap-2026.09.01-3p36hlnnsmcy1dmpbtadra` | 09-01T01:29:59Z | `…2026.08.24-000146` | `…2026.08.24-000202` |
| `daily-snap-2026.09.06-pbp7m5cerisso8hjjohmuw` | 09-06T01:29:59Z | `…2026.08.29-000156` | `…2026.08.29-000212` |

**結論: restore 込みで遡れる下限は 2026-08-16。ILM 7〜8 日 + snapshot 13 日 = 実効 21 日。**この 21 日という幅は固定で、窓ごと 1 日ずつ前進する（最古スナップショットが `expire_after=14d` で毎日 1 本失効する）。

**`metrics-*` はスナップショット対象外。**Prometheus / node metrics は ILM で消えたら復元不能。

**復元手順（コマンド例。未実行。実行には承認が要る）**

Step 1 — 対象バッキングインデックスを特定（読み取り）

```bash
curl -s -k -u "elastic:$PW" "$ES/_snapshot/s3-home-monitor/_all" \
 | jq -r '.snapshots[] | select(.snapshot=="<snapshot-name>")
          | .indices[] | select(startswith(".ds-logs-wlx-"))'
```

Step 2 — 別名へ restore（**書き込み。要承認**）

```bash
curl -s -k -u "elastic:$PW" -X POST \
  "$ES/_snapshot/s3-home-monitor/<snapshot-name>/_restore?wait_for_completion=false" \
  -H 'Content-Type: application/json' -d '{
    "indices": ".ds-logs-wlx-default-2026.08.16-000128,.ds-logs-wlx-default-2026.08.17-000131",
    "rename_pattern": "\\.ds-logs-wlx-default-(.+)",
    "rename_replacement": "restored-wlx-$1",
    "include_aliases": false,
    "include_global_state": false,
    "ignore_index_settings": ["index.lifecycle.name"],
    "index_settings": { "index.number_of_replicas": 0, "index.hidden": false }
  }'
```

Step 3 — 進捗（読み取り）

```bash
curl -s -k -u "elastic:$PW" "$ES/_cat/recovery/restored-wlx-*?v&active_only=true"
curl -s -k -u "elastic:$PW" "$ES/_cat/indices/restored-wlx-*?v"
```

Step 4 — 調べる / Step 5 — 削除（**書き込み。要承認**）

```bash
echo '{"size":50,"sort":[{"@timestamp":"asc"}],
 "query":{"bool":{"filter":[{"term":{"device":"wlx323"}},
   {"range":{"@timestamp":{"gte":"2026-08-16T00:00:00Z","lt":"2026-08-18T00:00:00Z"}}}]}}}' \
 | Q 'restored-wlx-*'

curl -s -k -u "elastic:$PW" -X DELETE "$ES/restored-wlx-2026.08.16-000128"
```

**落とし穴 4 点（実測確認済み。手順自体は未実行）**

1. **`index.lifecycle.name` を落とさないと復元直後に消える。**バッキングインデックスの settings は `index.lifecycle = {"name":"logs-wlx-7d","indexing_complete":"true"}`。`lifecycle_date` が既に 7 日超なので、ポリシー付きで復元すると次の poll（10 分以内）で delete される。`ignore_index_settings: ["index.lifecycle.name"]` は必須。
2. **rename 先がデータストリームテンプレートに当たると失敗する。**クラスタには 205 個の index template があり、`logs-wlx`(`logs-wlx-*`, data_stream) と `logs`(`logs-*-*`, data_stream) が該当。`logs-wlx-restore` のような名前は不可。`restored-wlx-…` はどのテンプレートにも当たらないことをパターン照合で確認済み。
3. **元インデックスは `index.hidden=true`。**復元後も hidden だと `restored-*` のワイルドカード検索に出ない。上記のように明示的に false にする。
4. **容量は問題にならない。**rtx のバッキングインデックスは 48.8〜122.4 MB/本、wlx は 1.4〜15.5 MB/本。16 本で 1 GB 未満。ノードの空きは es-0/1/2 とも 113.6 GB。

### 2.4 機器内蔵ログの遡及範囲

実機を read-only で probe した実測（2026-09-06 12:49 JST 前後）。

| 機器 | バッファ | 実測 最古 → 最新 | 遡及 | uptime |
|---|---|---|---|---|
| RTX1210 HND (.253) Rev.14.01.42 | 10,000 行 | 2026/09/06 12:06:16 → 12:48:09 JST | **42 分** | 24d 18h（boot 2026/08/12 18:46:32） |
| RTX830 ITM (.254) Rev.15.02.31 | 10,000 行 | 2026/08/29 20:06:56 → 2026/09/06 12:49:31 JST | **7.69 日** | 231d（boot 2026/01/18 02:54:36） |
| WLX323 (.6) Rev.25.01.08 | リングバッファ（容量未計測） | 2026/08/30 00:39:36 → 現在 | **7.51 日** | 7d 19:11（boot 2026/08/29 17:39:34） |

**RTX の遡及は「ログ流量の逆数」で決まる。**バッファは両機とも 10,000 行固定。ES 実測の日次流量:

| router | 08-29 | 08-30 | 08-31 | 09-01 | 09-02 | 09-03 | 09-04 | 09-05 |
|---|---|---|---|---|---|---|---|---|
| HND .253 | 195,755 | 249,394 | 239,812 | 245,710 | 220,330 | 205,570 | 193,748 | 274,376 |
| ITM .254 | 454,528 | 150 | 124 | 371 | 159 | 205 | 141 | 220 |

10,000 ÷ 240,000 行/日 ≈ 1 時間（HND 実測 42 分と整合）。ITM は 10,000 ÷ 200 ≈ 50 日の計算だが実測 7.69 日 — 08-29 の削減前の大量ログがバッファ前半を占めているため。**数日後には ITM の内蔵ログが ES より深く遡れるようになる。**ログ削減（#137〜#139）の副作用。HND は 42 分しかなく、内蔵ログを一次ソースにはできない。

**WLX323 の内蔵ログはリングで、boot 以降が全部残るわけではない**（前提の訂正）:

- 2026-09-06 01:53 JST 取得時の最古行は `2026/08/29 16:49:30`（`__ol_ath_attach` 等の boot 行）
- 同 12:51 JST 再取得時の最古行は `2026/08/30 00:39:36`（通常の ASSOC ログ）

11 時間の間に先頭が 7 時間 50 分ぶん進んだ。**リングは既にラップしており、boot（08-29 17:39:34）直後の約 8 時間分は失われている。**正しい表現は「最後の再起動以降、かつリングが溢れていない範囲」。リング実効は約 7 日 11 時間で uptime 7 日 19 時間を下回る。**ES の窓（7.5 日）とほぼ同じ長さなので、`show log` を ES の代替履歴として当てにはできない。**

---
