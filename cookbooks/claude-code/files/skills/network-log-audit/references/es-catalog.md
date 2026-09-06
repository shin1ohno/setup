# ES のログ参照先カタログ

どのデータストリームがどの問いに答えるか、logs-wlx / logs-rtx のコード辞書、BSSID とバンドの対応、syslog が届いていない機器。

as-of 2026-09-06。数値はすべて実測で、母数と窓を添えてある。
このファイルは `network-log-audit` skill の参照資料。実機は読み取りのみ。

---

## 1. ログの参照先

### 1.1 データストリーム一覧（何が答えられるか）

全 53 本のうち、Kibana 内部・ILM/SLM 履歴・Elastic 自己監視を除いた 12 本。件数と窓は 2026-09-06T03:55Z 実測。

| データストリーム | 実データ窓（最古 → 最新） | 総件数 | 件/日 | ILM policy | 実効保持 |
|---|---|---|---|---|---|
| `logs-rtx-default` | 2026-08-29T09:53Z → 現在 | 2,337,825 | 234,882 | `logs-rtx-7d` | **7〜8 日** |
| `logs-wlx-default` | 2026-08-29T15:46Z → 現在 | 218,011 | 30,529 | `logs-wlx-7d` | **7〜8 日** |
| `metrics-prometheus.collector-default` | 2026-08-05T05:33Z → 現在 | 763,996,910 | 24,582,009 | `metrics` | 30〜60 日（実測 31.9 日） |
| `metrics-system.network-default` | 2026-07-11T01:53Z → 現在 | 16,666,960 | 293,756 | `metrics` | 30〜60 日（実測 57 日） |
| `logs-system.journal-default` | 2026-05-02T17:27Z → 現在 | 8,204,982 | 28,435 | `logs` | **無期限** |
| `synthetics-tcp-default` | 2026-05-10T08:37Z → 現在 | 1,203,047 | 11,520 | `synthetics-…tcp…_policy` | ~395 日 |
| `synthetics-http-default` | 2026-05-10T08:37Z → 現在 | 1,299,456 | 10,080 | `synthetics-…http…_policy` | ~395 日 |
| `traces-apm-default` | 2026-07-30T07:43Z → 現在 | 445,102 | 14,538 | `traces-apm.traces-default_policy` | ~40 日 |
| `logs-elastic_agent.heartbeat-default` | 2026-05-10T08:28Z → 現在 | 5,108,873 | 43,200 | `logs` | 無期限 |
| `metrics-aws.billing-default` | 2026-07-06 → 2026-09-05 | 2,353 | 32 | `metrics@lifecycle` | 無期限 |
| `logs-nginx.access-default` | 2026-05-09T14:30Z → **2026-05-10T13:51Z** | 58,481 | **0（供給停止）** | `logs` | 無期限 |
| `logs-nginx.error-default` | 2026-05-09T14:30Z のみ | 89 | **0（供給停止）** | `logs` | 無期限 |

**答えられる問い**

| データストリーム | 問い |
|---|---|
| `logs-rtx-default` | どの端末がいつ WAN 側と何を話したか（HND の v6 セッション単位）。静的フィルタで何がいつ落ちたか。L2MS 配下スイッチのリンク断。IPsec トンネルの張り直し |
| `logs-wlx-default` | どの STA がどの BSSID にいつ associate / disassociate したか。認証がどこ（AUTH / 4-Way）で落ちたか。DFS レーダー・チャネル変更・バンド構成変更 |
| `metrics-prometheus.collector-default` | RTX と配下スイッチの毎ポート帯域・エラー・discard・リンク断（SNMP）。RTX の CPU/メモリ/温度。全 LXC の node_exporter。PVE ゲスト単位 I/O |
| `metrics-system.network-default` | LXC / PVE の毎インタフェース bytes・errors・drops。`pro` の `veth1NNi0` は CT ID 対応 |
| `logs-system.journal-default` | **PVE ホスト `pro` のみ**の OS ログ（ssh / cron / tailscaled / pveproxy / smartd） |
| `synthetics-tcp-default` | 8 エンドポイントの TCP 到達性（30 秒間隔）。**断の開始・終了を秒精度で押さえる唯一の時系列** |
| `synthetics-http-default` | 7 エンドポイントの HTTP 応答（30 秒間隔） |
| `logs-elastic_agent.heartbeat-default` | synthetics 実行側（CT111）の健全性 |

### 1.2 logs-wlx-default のコード辞書

母数 217,674（うち `code` 付き 115,009）、窓 2026-08-29T15:46Z〜2026-09-06T03:41Z（7.5 日）。

**主要フィールドと充足率**

| フィールド | 型 | 充足率 | 用途 |
|---|---|---|---|
| `device` | keyword | 100% | `wlx402` 167,871 / `wlx323` 49,724 |
| `host` | keyword | 100% | 192.168.1.5 / .6 |
| `severity` | keyword | 100% | notice 78,811 / debug 62,831 / info 55,288 / err 14,355 / warning 4,104 / alert 2,206 |
| `module` | keyword | 90.5% | kernel 78,724 / 80211-SEC 59,257 / 80211 56,133 / SYSTEM 2,537 ほか 16 種 |
| `sta` | keyword | 65.1% | 端末 MAC。ユニーク 49（ランダム MAC 込み） |
| `ap` | keyword | 53.1% | **BSSID**（バンド識別に使う） |
| `code` | keyword | 52.8% | 4 桁イベントコード、55 種 |
| `reason_code` | integer | 2.0% | 802.11 Reason Code（4,457 件） |
| `status_code` | integer | 1.7% | **wlx323 のみ** 3,617 件 |
| `client_ip` `client_mac` | ip/keyword | **0 件** | 未使用。使わない |

**BSSID → バンド対応**

| BSSID | 機器 | バンド | 件数 | 根拠 |
|---|---|---|---|---|
| `f4:d5:80:1d:59:58` | wlx323 | 2.4GHz (wlan101) | 5,927 | AP `show status` 実測（確定） |
| `f4:d5:80:1d:59:60` | wlx323 | 5GHz(1) (wlan201) | 12,473 | 同上（確定） |
| `f4:d5:80:1d:59:68` | wlx323 | 6GHz(1) (wlan301、2026-09-05 22:30 JST まで 5GHz(2)) | 7,910 | 同上（確定） |
| `f4:d5:80:1d:59:50` | wlx323 | 本体 MAC | 1 | 同上 |
| `ac:44:f2:49:5e:50` | wlx402 | **未確認** | 82,817 | — |
| `ac:44:f2:49:5e:51` | wlx402 | **未確認** | 3,279 | — |
| `ac:44:f2:49:5e:58` | wlx402 | **未確認** | 2,840 | — |
| `ac:44:f2:49:5e:52` | wlx402 | **未確認** | 244 | — |

wlx402 のバンド対応は ES 単体で確定できない（DFS イベントに `ap` が付かず、kernel ログの `name=ath5 freq=5180` と `sta` の突き合わせは 5180 側で 0 件一致）。確定手順は §4.1 の `show status airlink module`。

**コード辞書（件数の多い順、7.5 日窓）**

| code | module | 意味 | 件数 | 主な device |
|---|---|---|---|---|
| 0204 | 80211-SEC | 4-Way handshake 3/4 送信 | 17,697 | 402:16,179 |
| 0201 | 80211-SEC | Pairwise/Group 鍵交換 開始 | 15,977 | 402:14,429 |
| 0202 | 80211-SEC | 4-Way handshake 1/4 送信 | 15,977 | 402:14,429 |
| **0101** | 80211 | **AUTH REQ 受信（接続試行の分母）** | 12,885 | 402:9,111 / 323:3,774 |
| 0102 | 80211 | AUTH 応答送信 | 9,283 | 402:5,667 / 323:3,616 |
| 0103 | 80211 | ASSOC REQ 受信 | 5,658 | 402:4,060 |
| **0105** | 80211 | **STA associated（滞在の起点）** | 5,654 | 402:4,060 |
| 0104 | 80211 | ASSOC RESP 送信 | 5,653 | 402:4,060 |
| 0203 | 80211-SEC | 4-Way handshake 2/4 受信 | 4,545 | 402:3,029 |
| **0113** | 80211 | **STA 切断確定** | 4,108 | 402:3,763 |
| 0205 | 80211-SEC | 4-Way handshake 4/4 受信 | 2,391 | 323:1,497 |
| 0206 | 80211-SEC | 鍵交換完了＝WPA 認証成功 | 2,185 | 323:1,497 |
| 0112 | 80211 | AP → STA DEAUTH 送信 | 1,511 | 402:1,296 |
| 0115 | 80211 | AP → STA DISASSOC 送信 | 1,304 | 402:1,096 |
| **0126** | 80211 | **CCE（接続台数分散）で接続拒否** | 1,213 | **323 のみ** |
| 5122 / 5124 | SYSTEM | HTTPING 送信 / 応答（HTTP ステータス付き） | 各 1,080 | 323 |
| **0114** | 80211 | **無応答検出で切断（電波品質劣化の主サイン）** | 886 | 402:813 |
| 0121 | 80211 | 無応答タイマ満了（0114 と件数一致） | 886 | 402:813 |
| 0117 | 80211 | STA → AP DISASSOC 受信 | 854 | 323:828 |
| 0125 | 80211 | 同上・Reason Code 付き | 828 | **323 のみ** |
| 0109 | 80211 | STA → AP DEAUTH 受信 | 821 | 402:684 |
| 0110 | 80211 | 同上・Reason Code 付き | 821 | 402:684 |
| 0217 | 80211-SEC | PMK キャッシュ削除 | 493 | **323 のみ** |
| **0119** | 80211 | **AP 間ローミング検出** | 258 | 402:257 |
| 0123 | 80211 | AP → STA DEAUTH（RC 付き） | 215 | **323 のみ** |
| 0124 | 80211 | AP → STA DISASSOC（RC 付き） | 208 | **323 のみ** |
| 5113 / 5126 | SYSTEM | ログ / VS イベントログを FLASH へ保存 | 各 180 | 323 |
| 0127 | 80211 | バンドステアリング要求（2.4→5GHz 専用、**6GHz 非対応**） | 27 | 323 |
| 0503 | 80211-ACS | 接続中クライアントありで ACS 中止 | 24 | 323 |
| 6403 / 6404 / 6405 | FAST_DFS_V2 | 全 CH スキャン / CAC 開始（60 秒電波停止）/ 候補 CH 利用可 | 22 / 21 / 4 | 323 |
| 0305 | 80211-DFS | DFS チャネル再有効化 | 12 | 323:8 / 402:4 |
| **5111** | SYSTEM | **NTP 同期完了（offset 付き＝時刻ズレ検証に使える）** | 7 | 323 |
| **0303** | 80211-DFS | **レーダー検出 → 該当 CH を 30 分閉塞** | 3 | 323:2 / 402:1 |
| 0304 | 80211-DFS | チャネル変更 | 3 | 323:2 / 402:1 |
| 0501 / 0502 | 80211-ACS | ACS 開始 / CH 決定 | 各 3 | 323 |

低頻度（1〜3 件、全て wlx323）: `5120`/`5121` 無線 IF UP/DOWN、**`5137` バンド構成変更の唯一の証跡**（`Wireless LAN interface was changed from 5GHz(2) to 6GHz(1).`）、`5131` HTTP ログイン制限、`0301`/`0302` CAC 開始/終了、`6401`/`6408`/`6410`/`6411` Fast DFS v2、`6203` PoE 給電復帰、`0606`/`0607` コントローラ設定配信、`7001` MC→UC 変換、`7102` Proxy ARP 無効化。

**reason_code / status_code の実測分布**

| reason_code | 件数 | 出現 code | 802.11 規格名（未検証） |
|---|---|---|---|
| 2 | 1,559 | 0110 / 0113 / 0123 | Previous authentication no longer valid |
| 1 | 846 | 0125 / 0124 / 0110 / 0113 | Unspecified reason |
| 3 | 757 | 0110 / 0113 | STA is leaving |
| 6 | 394 | 0123 | Class 2 frame from nonauthenticated STA |
| 8 | 360 | 0125 / 0110 / 0124 / 0113 | STA leaving BSS |
| 30 | 310 | （kernel 由来） | Association denied, temporarily |
| 34 | 146 | 0123 | Disassociated due to poor channel conditions |
| 15 | 8 | 0110 / 0113 | 4-Way handshake timeout |

| status_code | 件数 | 対応 |
|---|---|---|
| 0 | 1,659 | 成功 |
| **37** | 1,213 | **`0126`（CCE 拒否）の件数と完全一致 → CCE 拒否**。規格名は未確認 |
| 126 | 627 | **未確認**（対応するイベントが見つからない） |
| 1 | 118 | Unspecified failure |

**2 台でメッセージ書式が違う（罠）**: `0102` は wlx402 が `Sent AUTH RESP to STA (…)`（Status Code なし、5,681 件全部 `status_code` 欠落）、wlx323 が `Sent AUTH RES to STA (…). Status Code: N`（3,617 件全部に付与）。**`status_code` で絞る解析は wlx323 にしか効かない。**

### 1.3 logs-rtx-default のコード辞書

RTX には `code` フィールドがない。分類軸は `event_kind` と `filter_no`。母数 2,335,529、窓 7.7 日。

| フィールド | 型 | 充足率 | 用途 |
|---|---|---|---|
| `router` | keyword | 100% | `hnd` 1,879,295 / `itm` 455,924 |
| `host` | keyword | 100% | 192.168.1.253 / .254 |
| `severity` / `facility` | keyword | 100% | `notice` 2,326,831 / `info` 8,388、`local0` |
| `event_kind` | keyword | 84.8% | `inspect` / `filter` / `swctl` |
| `src` `dst` `src_port` `dst_port` | ip/integer | 84.7% | |
| `protocol` `direction` `interface` `ip_version` | keyword/byte | 84.7% | `LAN2` 1,419,832 / `PP[01]` 454,878 / `TUNNEL[1]` 104,026 |
| `geoip_*` | 各種 | 70.2% | `geoip_location` は geo_point |
| `dyn_seq` `session_time` | keyword/date | 57.0% | inspect のみ。`session_time` は**セッション生成時刻** |
| `action` `filter_no` | keyword | 27.7% | filter のみ。`PASS` 454,347 / `REJECT` 192,853 |
| `sw_event` `sw_mac` `sw_path` | keyword | 0.06% | swctl（1,384 件） |
| `ike_event` `phase` `peer` `local` | text/keyword/ip | 1,075 件 | IPsec |
| `dhcp_event` `lease_ip` `mac` | keyword/ip | 186 件 | **ITM のみ**（HND の DHCPD 行は未パース） |
| `icmp_type` `rule` `tag` `repeat_count` `local_port` `peer_port` | — | **0 件** | マッピングにあるが未使用 |

**event_kind**

| event_kind | 件数 | router | 代表メッセージ |
|---|---|---|---|
| `inspect` | 1,331,536 (57.0%) | **hnd のみ** | `[INSPECT] LAN2[out][31] TCP <v6>.56609 > <v6>.443 (2026/09/06 12:33:02)` |
| `filter` | 647,200 (27.7%) | itm 454,878 / hnd 192,335 | `TUNNEL[1] Rejected at IN(300) filter: UDP A.B.C.D:67 > A.B.C.D:68` |
| `swctl` | 1,384 (0.06%) | **hnd のみ** | `[SWCTL] lan1:6(XX): lan1:2 link up (100-fdx)` |
| （なし） | 355,192 (15.2%) | hnd 354,059 / itm 1,046 | 下記「未パース」 |

**filter_no 辞書（全量）**

| filter_no | router | action | interface | dir | ver | 件数 | 中身 |
|---|---|---|---|---|---|---|---|
| `200099` | itm | PASS | PP[01] | IN/OUT | v4 | 454,347 | UDP 449,820 / TCP 4,224 / ICMP 303。**8/29 分のみ**（8/30 以降 `syslog=off` 化で消滅） |
| `300` | hnd | REJECT | TUNNEL[1] | IN | v4 | 104,099 | UDP dport 68:103,579 / 67:520 = トンネル越し DHCP ブロードキャスト |
| **`11`** | hnd | REJECT | LAN2 | IN | **v6** | 70,883 | **IPv6 戻りパケット拒否**。TCP 52,901 / UDP 17,982 = 動的セッションの戻り |
| `45` | hnd | REJECT | LAN2 | IN | v4 | 17,465 | ICMP 15,609 + UDP dport 138(NetBIOS) 1,856 |
| `200022` | itm | REJECT | PP[01] | **OUT** | v4 | 531 | UDP dport 137 の外向き拒否 |

**未パース 355,192 件（15.2%）の正体**（ランダムサンプル 800 件のクラスタリング）

| パターン | サンプル比 | 内容 |
|---|---|---|
| `LAN1(portN) Rejected at IN(N) filter: <MAC> > <MAC> IP` | 459/800 | **MAC ACL 拒否・IPv4** |
| `LAN1(portN) Rejected at IN(N) filter: <MAC> > <MAC> IP6` | 325/800 | 同・IPv6 |
| `[DHCPD] LAN1(portN) Extends <IP>: <MAC>` | 15/800 | **HND の DHCP リース更新** |
| `[DHCPD] Extends <IP>: <MAC>` (itm) | 1/800 | ITM の DHCP |

Vector の `filter_re` が IP フィルタ形式専用なので、これらには `event_kind`/`action`/`filter_no`/`src`/`dst` が一切付かない。**MAC ACL 拒否と HND の DHCP はフリーテキスト検索しか手がない。**実測: `message` に "DHCPD" を含む文書は 7.7 日で 4,850 件（hnd 4,576 / itm 274）だが `dhcp_event` が付いているのは 186 件。

**低頻度イベント**

IKE/IPsec 1,075 件 — `ike_event` `phase` `peer` `local`。文面 `[IKE] respond ISAKMP phase to <IP>` / `[IKE1] SA:N/IKE established` / `SA:N/IKE deleted` 等。トンネル張り直しの追跡に使う。

SWCTL（L2MS 配下スイッチ）1,384 件。`sw_event` 全量: `detect down` 426 / `find switch` 426 / `route updated` 424 / `lan1:2 link down`・`up (100-fdx)` 各 25 / `PORT2 link down`・`up (1000-fdx)` 各 23 / `PORT3 link down`・`up` 各 4 / `received config (*.conf)` 3 / `Airlink setting changed` 1。`sw_mac`: `ac:44:f2:5a:d7:20` 639 / `ac:44:f2:09:f7:3d` 638 / **`ac:44:f2:39:07:13` 54（SWX2100-5PoE）** / `ac:44:f2:64:d2:84` 50 / `f4:d5:80:1d:59:50` 2（WLX323 本体）/ `ac:44:f2:49:5e:48` 1（WLX402 本体）。

**リンクフラップを日別件数で判定しないこと。**down/up の継続時間で見る（§3 / §5.2）。

### 1.4 syslog が届いていない機器（調査の穴）

`logs-rtx-default` + `logs-wlx-default` の `host` terms agg 全量（母数 2,555,896）:

| host | 件数 | 機器 |
|---|---|---|
| 192.168.1.253 | 1,879,737 | RTX1210 HND |
| 192.168.1.254 | 455,924 | RTX830 ITM |
| 192.168.1.5 | 168,235 | WLX402 |
| 192.168.1.6 | 49,724 | WLX323 |

| 機器 | syslog | メトリクス | 判定 |
|---|---|---|---|
| RTX1210 HND (.253) | あり | SNMP あり | OK |
| RTX830 ITM (.254) | あり | SNMP あり | OK |
| WLX402 (.5) | あり | **無し** | 部分的 |
| WLX323 (.6) | あり（2026-08-17 以降） | **無し** | 部分的 |
| **WLX313 ITM (.155)** | **0 件** | **無し** | **穴** |
| SWX2100-5PoE (`ac:44:f2:39:07:13`) | 自前無し | RTX SNMP 経由で 5 ポート | 間接的 |
| SWX2110P-8G (`Z7K01199CX`) | 自前無し | RTX SNMP 経由で 8 ポート | 間接的 |

**穴 1: WLX313 (.155) の syslog がゼロ** — positive control 済み（同形クエリで `.5` は 168,235 件、`.253` は 1,879,799 件）。機器自体は生存（フリーテキスト `"192.168.1.155"` が `logs-*`/`metrics-*`/`synthetics-*` 横断で 31 件、全て ITM RTX の `[DHCPD] Extends 192.168.1.155: ac:44:f2:5a:d7:20` = 6 時間ごとのリース更新）。Vector の VRL が送信元 IP を `.253/.254/.5/.6` の 4 つにしかマップせず、それ以外を `abort` する。**ITM 拠点の Wi-Fi 事象は ES では一切追えない。**

**穴 2: LXC 全台の journald が 2026-05-16 で停止** — `logs-system.journal-default` のホスト別最終出現は `pro` のみ現在（3,558,169 件）、`pro-dev`/`monitoring`/`cognee`/`memory`/`consent`/`weave`/`roon-mcp`/`pro-router`/`es-0..2` が 2026-05-16、`kibana` 2026-05-31、`nrt-subnet-router` 2026-05-10、`praeco` 2026-05-18。filebeat は 9 台で稼働継続中なので journald input だけが落ちている。**unbound / Vector / Prometheus / Grafana / Docker のサービスログは ES に一切入らない。**

**穴 3: nginx access / error が 2026-05-10T13:51Z で停止**（ILM 無期限なのでデータは残るが供給が止まっている）。

**穴 4: WLX AP にメトリクスが無い** — Prometheus の instance 一覧に `.5`/`.6` が無い。**接続台数・RSSI・チャネル使用率・再送率は ES に存在しない。**数量的な電波品質は AP に telnet して読む（§4.1）。

**穴 5: Vector 自身のメトリクスが ES にも Prometheus にも無い** — エンドポイント自体は生きている（`http://192.168.1.76:9598/metrics` が応答）。直接読んだ実測（uptime 228,015 秒 = 2.64 日、2026-09-06T03:52Z）:

| コンポーネント | received | sent | 差 |
|---|---|---|---|
| `rtx_udp`（socket UDP 514）| 714,706 | 714,706 | 0 |
| `parse`（remap）| 714,706 | 705,248 | **9,458 欠落（1.32%）** |
| `parsed_rtx_for_es` | 705,248 | 638,247 | 67,001（wlx 分を意図的に破棄） |
| `parsed_wlx_for_es` | 705,248 | 67,001 | 638,247（rtx 分を意図的に破棄） |

`vector_component_errors_total` は 1 つも出ていない。**syslog がサイレントに落ちたときの ES 側の検知手段が存在しない。**

**穴 6: es-memory (192.168.1.72) の node_exporter が 30 日以上 down**（日別平均 up=0.000、2026-08-07〜09-06 の全 31 日、母数 86,382 サンプル）。

**日別件数の推移（穴の判定基準）**

`logs-rtx-default`: 08-29 hnd 195,755 / itm 454,528 → 08-30 以降 itm は 124〜371 件/日。**8/29 の PR #139（dynamic フィルタの syslog 抑止）が原因**であって機器障害ではない。hnd は 193,748〜274,376/日で継続。

`logs-wlx-default`: 08-30 10,737 / 08-31 16,089 / 09-01 8,098 / 09-02 15,410 / **09-03 112,083** / 09-04 15,173 / 09-05 29,954 / 09-06 10,430。09-03 のスパイクは wlx402 108,961 件（kernel 46,527 / 80211-SEC 36,559 / 80211 26,917、code は 0204:12,467 / 0201:10,859 / 0202:10,859 / 0101:6,530 = 認証の繰り返し）。

---
