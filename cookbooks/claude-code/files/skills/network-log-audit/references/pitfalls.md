# 既知の罠

観測パイプラインが嘘をつくケース、機器・プロトコル固有の罠、時計とタイムスタンプ、恒久対処と巻き戻し条件。

as-of 2026-09-06。数値はすべて実測で、母数と窓を添えてある。
このファイルは `network-log-audit` skill の参照資料。実機は読み取りのみ。

---

## 5. 既知の罠

### 5.1 観測パイプラインが嘘をつくケース

ES に 0 件、ダッシュボードに変化なし、plan に差分なし、alert が緑 — このいずれも「機器が正常」の証拠にならない。実際に嘘をついた経路:

| 見えた状態 | 実際に起きていたこと | 見抜いた probe |
|---|---|---|
| `logs-wlx-default` に wlx323 が 0 件 | AP の実 IP は `.27` なのに `devices.tf`/`vector.toml` が `.41` と宣言。Vector の `parse` は送信元 IP マップ外を `abort` するため約 **20 万件/日を無音破棄**。`.41` の実体は別の Wi-Fi クライアント | PVE ホスト(.10) で `tcpdump -i vmbr0 -nn 'udp port 514 and dst host 192.168.1.76'`。加えて `component_discarded_events_total{component_id="parse"}` を 30 秒間隔で 2 回読み差分を取る（`:9598`、9080 ではない） |
| HND の IPv6 障害が Kibana / Grafana に出ない | `vector.toml:137` の `filter_re` が `(?P<src>[\d.]+)…` = **IPv4 専用**。HND ログ 384,377 件/24h のうち 382,526 件（**99.5%**）に action/src/dst/geoip が付かず集計と GeoIP から丸ごと抜ける。`[INSPECT]` 行（16.3 万件/日）も未パース | v6 は構造化フィールドを使わず `message` を grep |
| WLX313（ITM, .155）に障害の兆候ゼロ | WLX313 は syslog を送っていない = **監視の穴であって健全性ではない** | `logs-wlx-default` の device 別内訳（§1.4） |
| ITM の設定は正しく見える | `config.txt.tftpl` が `.20`/`local1`、実機は `.76`/`local0`。`null_resource.copy_config_to_itm` の SFTP push は `/system/config0` = **保存設定のみで running には未適用** → 再起動時に壊れる時限爆弾。2026-08 にはドリフト 5 件（SNMP 一式が実機のみ 等） | 実機 running config と描画結果を突き合わせる。**テンプレートは running の証拠にならない** |
| `terraform plan` に差分ゼロ | provider 0.16.1 は `rtx_access_list_ipv6_dynamic.source` と `apply.dynamic_sequences` を読み戻さない（実機 `dhcp-prefix@lan2::/64` に対し state `"*"`）。**差分は「config と state の差」であって「config と実機の差」ではない**。0.14.1 以前は `dhcp_scope`/`dns_server` が SFTP で**保存設定**を読んでいた | 実機を `-tt` で直接読む（§4.2） |
| snmp_exporter のログに古いエラー行だけ | snmp_exporter は**失敗のみログする**（成功スクレイプは無音）。「Last error at HH:MM:SS」＋以降の行なし＋`up=1` は復旧済み | Prometheus（`localhost:9090`）でメトリクスを引く。ホストから `curl snmp-exporter:9116` は docker サービス名が解決できず `http=000` を返すが SNMP 障害ではない |
| フィルタ番号でログの出所を同定した | 静的 `ip filter 200099` と動的 `ip filter dynamic 200099` は**同じ番号の別オブジェクト**で、ログ行はどちらも `PP[01] Passed at IN(200099)`。静的側を pass-nolog にしても変化ゼロ、動的 2 本（200098 tcp / 200099 udp）を `syslog=off` にした瞬間 21,910 件/分 → 0 | `show config \| grep "filter dynamic"` まで見る |
| unbound-watchdog が緑のまま home.local が SERVFAIL | canary が local-data なので、forward 先だけが wedge した障害では常に緑 | **監視の canary が障害クラスを通過するか**を設計時に確認する |
| RTX probe の `show log \| grep …` が空 | 出力が巨大で RTX 側 grep が返る前に drain 窓が閉じ、**マッチ 0 件と区別がつかない空文字**が返る | ログは ES 側で引く |
| ES クエリが 0 件 | **IPv6 アドレスへの `match_phrase` は既知在存アドレスでも 0 件**（アナライザがコロンで分割する） | token の `match`（例 `"fe00:67"`）で引いてローカルで grep |
| `ping` が 100% loss | AWS Route53 Resolver（10.33.128.2）は ICMP に応答しない | `dig @10.33.128.2 <name>` |
| AP の config push を `logs-rtx-default` で探して見つからない | push しているのは RTX ではなく WLX323 自身（standalone = 自分が仮想コントローラー）。`[WLC-CON]` は `logs-wlx-default` の device=wlx323 発 | ストリームを跨いで device 別に内訳を取る |
| ステアリング機能が設定上有効 | `ath_ap_steering_netlink_send` の宛先 userspace pid が 9 日間 1,485/1,485 件すべて未登録で破棄 = 11k/v・SON ステアリングは実質不活性 | 設定値ではなく**送信結果のログを数える** |
| provider の apply が成功した | `rtxClient.SaveConfig` は `executor.Run` の出力を `_` で捨て `checkOutputError` を呼ばない。エラーを印字してプロンプトに戻ったルータも成功扱いになる | 実機で `save 0` を打ち直す |
| SSM 経由のパイプラインが「管理されている」 | `ingest-drop` は home-monitor が `/ingest/drop/*` を publish し setup 側が `/ln/*` を読んでいた = 構造的に動かない死んだ経路（2026-06-07 撤去） | publish 側と consume 側のパスを**両方**読む |

**「0 件」を報告する前の 4 点チェック**

1. **positive control を取る。**既知在存の値で同じクエリが非ゼロを返すか。
2. **送信側で実測する。**ES / Vector のメトリクスだけでは「届いていない」と「捨てられている」を区別できない。
3. **パーサを通過しているか確認する。**v6 行・`[INSPECT]` 行・MAC ACL 行は未パースなので構造化フィールドでは引けない。
4. **その機器がそもそも syslog を送っているか確認する**（WLX313 の穴）。

### 5.2 機器・プロトコル固有の罠

**RTX — DNS**

- **HND RTX1210 の DNS forwarder は UDP のみ。TCP/53 は connection refused**（2026-05-30 実測）。RFC 7766 では TC ビット付き応答は TCP 再試行が必須なので、DNSSEC・長い TXT/SPF・多 A レコード・CNAME 連鎖で Linux の名前解決が間欠的に失敗する。対照として 1.1.1.1 は TCP/53 OPEN。
- **`dns host bridge1` は lan1 を含まない。**RTX の DNS listener は bridge1（lan3+tunnel1）に bind しており、lan1 からの UDP/53 は無言 drop、TCP/53 は refused。
- **RTX は同一セグメントの next-hop へハンドピン転送しない。**`rtx_static_route.aws`（10.33.128.0/18 → .60）があっても、.253 をゲートウェイにした LAN ホストの 10.33.128.0/18 宛は破棄され ICMP redirect も出ない。証拠: LXC から `ip route add 10.33.128.0/18 via 192.168.1.60` を足した瞬間に `dig @10.33.128.2` が通る。
- **DHCPv6 で死んだ v6 DNS を配っていた**（2026-09-03 まで）。`o_flag=on` + 明示 DNS option なしで既定の lan1 アドレス `240f:146:70c8:2::1` を広告するが、上記のとおり lan1 では応答しない。実測 `dig @240f:146:70c8:2::1 www.google.com` = UDP timed out / TCP refused。macOS/iOS が DHCPv4 の resolver と merge して周期的に 1〜2 秒の per-server timeout を払う（**この merge 挙動自体は未実測**）。
- **VPC resolver 10.33.128.2 の DNS64 は黒穴**だった。`enable_dns64=true` により A のみの名前に `64:ff9b::/96` を合成するが LAN に NAT64 GW は無い。実測 `dig @10.33.128.2 github.com AAAA` = `64:ff9b::141b:b171`、対照 `@1.1.1.1` は空。Happy Eyeballs が先に v6 を試して失敗し、接続ごとに 250ms〜6s。
- **unbound（CT118 .61）の forward wedge**: forwarder の RTO が 120000ms 上限に張り付くと経路復旧後も home.local が SERVFAIL のまま。`unbound-control lookup <name>` で `rto 120000 msec` を確認、`unbound-control flush_infra 10.33.128.2` で復旧。
- **unbound の「受信するが返さない」wedge**: サービス active・bind 済み・nft all-accept・ARP 正常なのに外部からは無応答、localhost だけ応答。`num.queries` は増え続けていた。PVE ホスト側で `tcpdump -nni veth118i0 'port 53'` を取り「クエリは届く・応答は 1 つも出ない」を確定。`systemctl restart unbound` で回復。

**RTX — IPv6 dynamic filter**

- **UDP セッションはアイドル 30 秒で失効し、`timeout=900` は効かない**（2026-09-03 制御プローブで確定）。blackhole 宛と STUN 宛の 2 フローが最終パケットの 30 秒後に同時解放され、**戻りパケットの受信は延命しない**。別測定でも UDP(entry 36) の 85%（2,122/2,483）が 30-31s に集中、TCP(entry 31) は p50=11s / p90=72s / max=16,203s でアイドルタイマを尊重。
- **失効後の QUIC 戻りは終端 static reject IN(11) で落ちる。**慢性比率は送出 v6 セッションの 6〜8%（PR #128 以降ほぼ一定 = 最近の regression ではない）。episode 最大 2,123 秒、66% は同一 5-tuple の再送。v4 は NAT のため無関係。
- **in チェーンは dynamic セッションテーブルを参照しない。**reject を直後の `show ipv6 connection detail` と 5-tuple で突き合わせると 53%（17 件中 9 件、別ラン 9 件中 5 件）が `state=E` ESTABLISHED の戻りだった。`in ... dynamic 6 31 36` を張ると失敗率 4.40%（205/4,654）→ 2.18%（74/3,389）に改善するが、`* * tcp` / `* * udp` なので**外部起点の最初の 1 パケットでもセッションが張られ**（数分で `LAN2[in]` に 102 セッション）、v6 の default-deny が allow-on-first-packet に変わる。
- LAN 限定 dynamic を設計する際の制約 3 点: (a) in チェーン参照時に src/dst が「セッション開始側」で評価されるか「通過中パケット」かが**未解決**、(b) ルータ自身の外向きセッションは WAN 側 /64 から出るので LAN /64 に絞るとルータ自身の名前解決が止まる、(c) `ipv6 prefix 1 dhcp-prefix@lan2::/64` の委任プレフィックス追従なので、`240f:146:70c8::/56` 等をハードコードすると ISP のローテーションで無言で全 v6 が止まる。

**RTX — DHCP バインド**

- **ランダム化 MAC を静的 DHCP バインドに登録してはいけない。**macOS の「プライベート Wi-Fi アドレス」が `devices.tf` に入っており、ローテートで静的 binding（.33）にマッチせず動的プール（実測 .66）へ。判別は先頭オクテットの bit1（0x02）— セットならローカル管理 = ランダム化。Apple 実 OUI は `14:7f:ce` / `64:4b:f0` 等。
- **Apple 端末は DHCP option 61 を送るので RTX は client-ID で照合する。**bare-MAC 形式の bind は Apple にマッチせず動的プールへ。非 Apple（PVE LXC `bc:24:11:*`、東芝 AC）は bare-MAC でマッチする**非対称性が手掛かり**。`show status dhcp` のリース表示が「クライアントID: (01) …」なら option 61、「クライアントイーサネットアドレス」なら未送出。`show config` の `ethernet <mac>` が client-ID 形式（type 0x01）。**このフラグは Apple 端末にだけ適用する**（非 option 61 機器を client-ID 形式にすると逆にマッチしない）。バインド変更は既存の動的リースを持つ端末を動かさないので、再 DHCP（ドック抜き差し / Wi-Fi トグル）が要る。

**RTX — MAC ACL / フィルタ / save / provider**

- **`rtx_access_list_mac` を destroy / `count = 0` してはいけない。**provider の Delete はインターフェースの bind を外さずに `no ethernet filter <num>` を撃つため、pass-all（entry 100）が消えた瞬間に lan1 が存在しないフィルタを参照して **implicit deny → LAN 全体のインターネット断**、provider 自身の SSH も切れて `Still destroying...` が 14 分継続（2026-07-25 実測、DynamoDB に stale lock、実機設定は無傷）。解除は **UPDATE**（entry 100 と両方の `apply { interface = lan1 }` を常に残し、reject entry 1&2 だけ落とす）。Update は削除エントリを `no` しないので 1&2 は定義済み・未 bind で残る（inert）。
- **`save` と `save 0` は別物。**裸の `save` は `external-memory config filename` に従い、USB を指していて USB が無いと `External memory is not mounted` → 保存先変更 Y/N → スロット選択のプロンプトで止まる（provider が撃つのはこの形）。`save 0` は常に内蔵 nvram へ行き何も聞かない。**`no external-memory config filename` は間違い**で USB を指す工場出荷既定に戻る。正しくは `external-memory config filename off`。切り分けは**設定値と USB の有無の両方**を見る（USB があれば設定はそのままで正常動作するため設定値だけでは断定できない）。
- **`reject-nolog` / `pass-nolog` は provider 0.16.3 以降。**0.16.2 まではスキーマ validator が 4 種しか許さなかったが、パーサ（`parsers/ip_filter.go:45`）とコマンド生成は 9 種すべて扱えていた。「下層は対応済み・スキーマだけ古い」パターンは他の属性でも起こりうる。
- **`terraform init -upgrade` は全 provider を上げる。**rtx だけ上げるには `.terraform.lock.hcl` から該当ブロックを削除してから `terraform providers lock -platform=linux_amd64 registry.terraform.io/shin1ohno/rtx`（ブロックを残すと「変更不要」と判定される）。
- **tunnel インターフェースの apply は read で空が返る**ので、plan の `sequences = [] -> (known after apply)` は正常（`rtx-hnd.tf:804` のコメント）。
- **dynamic filter 群への apply は v6 セッションを一度フラッシュする。**エントリ 11 本の書き直しで直後の 5 分バケットに 1,350 件規模の reject burst（平常時 8〜287 件）。静かな時間帯に他の変更と同乗させる。
- **実験中の apply は `-target` で絞る。**実機に out-of-band の実験値が入っている間、無指定 apply は `rtx_access_list_ipv6_dynamic.wan_outbound` を書き戻して実験を消す。

**WLX（無線 AP）**

- **WLX323 の無線・LLDP 設定は Web GUI 専用で、CLI からは設定できない。**Rev.25.01.08 のコマンドツリーを `?` で全走査した結果、channel も lldp も無い（`airlink ?` = configure/disable/emergency-mode/enable/macaddress/psk-key/select/ssid）。`show config` が ` airlink channel range default` と出すのは**出力形式であって入力形式ではない**。WLX302 世代のコマンドリファレンスは WLX323 に適用できない。CLI は読み取りと `save` には使える。
- **GUI のアカウントは telnet と別。**SSM の管理者パスワードは telnet を通すが、HTTP GUI では `administrator` / `shin1ohno` のどちらでも 401（`root` は 403）。ユーザーレベルでログインしても `show config` は `Error: Administrator use only`。
- **6GHz は 5GHz(2) の排他置換**（公式: 同時使用不可）。切替の副作用が 3 つ、いずれも時間帯効果に依存せず確定: (a) **CCE（接続台数自動分散）が仕様上まるごと無効**（5GHz(2) 使用時のみ利用可能）— 実測で拒否率 37.68%（1183/3140）→ 0.00%（0/72）、P≈3e-15、running config から `airlink cce use on` が消滅、(b) **band steering は 2.4→5GHz 専用で 6GHz を扱えない**、(c) 6GHz は約 **6.7 dB 不利**（Tx 19 dBm / 5GHz は 22 dBm、160MHz 幅で雑音床 +3 dB。実測 RSSI −65 / −73 dBm、MINRSSI −76 dBm、phymode HE160）。
- **`<0124> Reason Code: 1` は追い出しではない。**実測 14 件すべてが同一 STA が 2 秒以内に別 BSSID へ associate した直後の在籍片付けで、純粋な追い出しは 0 件。件数はバンド移動回数の言い換えにすぎない。分類するなら「直前 2 秒以内に別 BSSID への `0105` があるか」でイベント単位に。
- **W52 固定は禁止。**Yamaha の Fast DFS v2 は「レーダー検出で 5GHz(1) が W52 になると停止し、W53/W56 が使用可能になってもチャンネルは W52 から戻らない」。現状の `channel range default` + `channel range dfs default` が Fast DFS v2 を有効に保つ設定。
- **config バックアップは秘密情報。**管理者パスワードは `administrator password encrypted <hash>` で復元できないが、`airlink psk-key` は**平文**。
- **`ap_config_exec.json` をスクリプトから叩いてはいけない。**`proc` の意味は 保存=`1` / **復元=`0`** / 削除=`2`（`/define.js` の `CONFIG_CONTROL`）。ダイアログ div の hidden input は 3 つとも `value="1"` のプレースホルダなので **HTML だけで GET/SET を判別してはいけない**（真の値はボタン側の `proc` 属性）。打ち間違えると古い設定が push されて AP が再起動する。

**PVE / LXC・SSM**

- **bpg provider は `memory.dedicated` の変更で LXC を再起動する。**`terraform plan` は「will be updated in-place」としか出さず再起動は現れない。実測: CT118 `uptime -s` = 21:51:32、unbound `ActiveEnterTimestamp` = 21:51:34、PVE task log に `vzreboot:118:root@pam!terraform`（2026-09-03、約 5 秒断）。対象が resolver（CT118）/ monitoring（CT111）/ router（CT102）なら、apply 前に冗長経路の生存を確認し「数秒〜十数秒の再起動あり」を報告に書く。
- **SSM パラメータは Advanced → Standard に下げられない**（2026-08-29 に捨てパラメータで実測: `ValidationException`）。`/host-registry/devices` は 4,006 バイト（version 14、26 エントリ、上限 8,192）。

**ES / Prometheus クエリ**

- **`ifOperStatus` は enum 3 系列。**snmp_exporter は 1 スクレイプにつき `up` / `down` / `testing` の 3 系列を出す（実測: down 4,284,949 / testing 4,284,945 / up 4,284,944 docs）。素直に値で terms を取ると**必ず `0.0 : 1.0 = 2 : 1`** になり全ポートがフラップしているように見える。正しくは **ラベル `prometheus.labels.ifOperStatus == "down"` かつ 値 == 1**。
- **Prometheus のラベルは `prometheus.labels.job` で絞る**（`labels.job` ではない）。メトリクス名は 729 種、値は `prometheus.metrics.<metric_name>`。
- **IPv6 に `match_phrase` は効かない**（上表参照）。

**シェル・ツール**

| 罠 | 症状 | 対処 |
|---|---|---|
| `grep` が制御バイトでバイナリ判定 | `show log` の捕捉ファイルに grep して**何も出ない（`0` すら出ない）** | **`grep -a` 必須**。実測: `-a` 無しで無出力 → 有りで 5,783 行 |
| `cd` の chpwd フック | `cd /tmp && python3 …` で `tree` 出力が数百行流れ、本来の出力が埋もれる | `cd` を使わない。絶対パス引数か `git -C` |
| LAN マップ API の散発 401 | 認証方式の問題に見える | **同一コマンドの再試行で 200**（追試 4/4）。`--anyauth` は不要 |
| LAN マップ API のパス | `/api/lan_map_data_init.json` が 404 | 正しくは `/lan_map/` 配下 + `?lan_no=1&page=1` 必須 |

### 5.3 時計とタイムスタンプ

| 事実 | 数値と窓 | 含意 |
|---|---|---|
| **ES の `@timestamp` は装置時刻ではなく Vector の受信時刻** | RTX1210 Rev.14 / RTX830 Rev.15 の syslog は `<PRI>tag msg` 形式で **TIMESTAMP も HOSTNAME も無い**（`vector.toml` の実装コメントに明記）。`socket` source が受信時刻を入れる | ES の時刻は CT111 の時計に従う。装置時計のドリフトは ES に現れない。逆に装置の `show log` と突き合わせるときは装置時計のずれを別途測る |
| HND RTX1210 の内蔵時計が進んでいる | 2026-08-23 +292s / 2026-09-03 +301〜306s / **2026-09-05 +308s**（Cloudflare / Google の HTTP `Date` を真値として実測） | 他システムとのログ突合が約 5 分ずれる |
| ドリフトは 1.2 秒/日 | 08-23 の +292s → 09-05 の +308s、13 日で +16s。+308s の大半は 2026-08-12 起動時点で既にあった約 278s のオフセット | **日次 ntpdate で誤差 1.2 秒**に収まる。毎時にする必要はない。起動直後だけは次の 00:00 まで補正されない |
| **HND の現在の skew は ±1 秒以内**（2026-09-06 実測） | `show environment` を 3 回、ホスト時刻で挟んで測定: [-1.9s,+0.2s] / [-2.0s,+0.1s] / [-1.1s,+1.0s]。running config に `schedule at 1 */* 00:00 * ntpdate ntp.nict.jp syslog` が存在 | メモリ `rtx-log-pipeline-findings-2026-08.md` の「+292s、ntpdate 無し」は**現状と合わない**（2026-09-06 に ntpdate schedule 投入済み） |
| ITM RTX830 の skew ≈ 0.2 秒 | 自分が打った `show environment` が `[MMI] Executed by SSH(shin1ohno): show environment` として ES に届き、装置時刻 12:49:30 JST に対し ES の `@timestamp` が `03:49:30.225Z`。`config.txt.tftpl:194` に ntpdate schedule | **2 台の時計を同列に扱わない。**HND には `syslog execute command on` が無いため MMI 行が ES に出ず、HND の時計は pty 測定でしか確認できない |
| `ntpdate <server> syslog` は補正量を 1 行で返す | 2026-09-06 00:02:44 HND 実測: `2026/09/06 00:02:44  -307second`。外から測った +308s と 1 秒以内で一致 | 日次 schedule の発火確認はこの行を探す（ルータのログは巨大で probe から grep できないので **ES 側で引く**） |
| **`[INSPECT]` はセッション解放時に出力され、埋め込み timestamp は生成時刻** | — | 「ログが出た時刻」を「事象が起きた時刻」と読むと**二重にずれる**（解放 vs 生成 + 機器時計オフセット） |
| `session_time` はセッション継続時間を含む | `@timestamp - session_time` の中央値は +29.8s だが時計ずれの推定には使えない（最小値 +4.8s のほうが上限として近い） | 時計ずれ推定に `session_time` を使わない |
| `show config` は日次スケジュールをレンダリングし直す | HND 実測: `schedule at 1 0:00 * ntpdate …` と書いたものが `schedule at 1 */* 00:00 * ntpdate …` で返る（日付が補われ、時は 2 桁ゼロ埋め、**秒は付かない**）。ITM の `00:00:00` は push した config.txt の記述がそのまま保たれたもの | 読み戻しは `H:MM`/`HH:MM`/`HH:MM:SS` × 日付あり/なしの全組合せを受理する必要がある（provider 0.16.4 は対応済み） |
| WLX の NTP 同期完了は `<5111>` に offset 付きで出る | `Completed NTP Synchronization. 2026/09/06 00:00:01 offset 0.798338 sec`（7.5 日窓で 7 件） | WLX の時刻ズレはこのコードで検証する |

**未確認**: 「AP は NTP 同期前に 2023/01/01 のログを出す」という挙動は、メモリ 25 本のいずれにも記載がない（`grep 2023` で 0 件）。WLX 側の NTP 未同期時の時刻挙動は未確認。

### 5.4 恒久対処と巻き戻し条件

「直っている」ものには、それが**どうやって戻るか**が付いている。「以前直したはず」と思ったら、まず巻き戻し条件を確認する。

| 対処 | 適用形態 | 巻き戻る条件 |
|---|---|---|
| WLX323 の LLDP 無効化（2026-08-29、SSID 消失の根治） | AP へ GUI から config push。CLI では設定できない | **RTX の LAN マップ「CONFIG の復元」がワンクリックで巻き戻す。**`/ap_config/f4_d5_80_1d_59_50.conf` は 2026-08-21 = 修正前で、復元は AP を再起動する。**AP 設定を変えたら必ずバックアップを取り直す。**なお `lldp` は config.txt の device-local 部にしか無く VC プロファイルに対応行が無いため、仮想コントローラーからの push では上書きされない（修正が生き残った理由） |
| HND の `external-memory config filename off` + provider 自動 save の復旧（2026-08-23） | 機器レベルの設定。`rtx-hnd.tf` には無く CONFIG0 に永続 | **工場出荷リセットで失われる。**2026-06-07 の同じ修正が 08-23 には `usb1:/config.txt 0` に戻っていた（間に誰も実機を読まなかった 2.5 か月）。ITM RTX830 は**未確認** |
| HND SNMP ACL の Terraform 管理化（provider v0.15.0 + PR #83） | Create/Update が `SaveConfig` を呼ぶので running と保存設定の両方に載る = 再起動に耐える | 元の事故は「out-of-band で入れて save していない設定が再起動で消える」形。**out-of-band で入れた設定は再起動で消える**が原則 |
| SNMP 消失の検知（setup PR #411 `RTXSnmpTargetDown`、`up{job="snmp-rtx"}==0 for 10m`） | CT111 の Prometheus alert | terraform は plan/apply 時にしかドリフトを見ないので、runtime の消失検知はこの alert が唯一 |
| ITM syslog テンプレートの実機整合（PR #92/#93、ドリフト 5 件を #139 で解消） | `config.txt.tftpl` → SFTP で `/system/config0` へ push | push 先は**起動時に読まれる設定**。テンプレートが実機からずれている間は、ITM を再起動した瞬間に SNMP が消えてログが増える |
| home.local を unbound のローカルデータ化（#85 → SSM `/host-registry/home-local-records` 27 名） | unbound が `local-zone static` + `local-data` を SSM から生成 | 前提として RTX 側の `rtx_dns_server` `hosts` ブロックを撤去済み（#87）。**RTX 静的 A はもう冗長経路ではない。**unbound がローカル解決をやめれば VPC 依存に戻る |
| unbound-watchdog（setup #404、PVE から 60 秒周期でオフボックス probe → `pct exec 118 systemctl restart unbound`） | PVE ホストの oneshot + timer、node_exporter textfile + alert | canary が local-data だけだと forward wedge を見逃す（#424 で forward-path probe + `flush_infra all` を追加）。`interface-automatic: yes` は #405 で除去済み（**再投入は flapping の再発**） |
| DHCPv6 の死んだ v6 DNS 停止（PR #143、`m_flag=off o_flag=off`） | 実機適用済み・CONFIG0 保存済み。2026-09-05 に `scutil --dns \| grep 240f:146:70c8:2::1` が 0 行を 3 回確認 | 起点は 2026-08-12 の loopback/DHCPv6 cutover（PR #121）。同種の cutover で再発しうる |
| VPC DNS64 の無効化（PR #142、`enable_dns64=false` ×4 subnet） | `dig @10.33.128.2 github.com AAAA` / `ipv4only.arpa AAAA` とも空を実測 | NAT64 GW が無い限り true に戻すと黒穴が再発 |
| v6 dynamic の `timeout=900` 実験の撤去（2026-09-03） | entry 31/36 を**削除ではなく再投入**して宣言に一致させ `save` で CONFIG0 反映。`in` チェーンが参照中なので削除してはいけない | 慢性 6〜8% の v6 QUIC 戻り reject は受容した状態 |
| tunnel v6 block の `reject-nolog` 化（HND ログの 56% を 0 に） | provider 0.16.3 以降でのみ書ける | provider を 0.16.2 以前に戻すとスキーマ validator が弾く |
| MAC ACL（living_tv ブロック）の運用形 | entry 100（pass-all）と両方の `apply { interface = lan1 }` を**常に残す**。解除は reject entry 1&2 を落とす UPDATE のみ | destroy / `count = 0` で LAN 全断（§5.2） |
| wlx323 を `.6` へ移設（setup #887 / home-monitor #123） | `.27` は RTX の動的プール `.20-99` の内側で予約が無く他クライアントにリースされうる。`.6` はプール外 | AP の IP を動的プール内に置き直すと同じ無音破棄が再発 |
| `/host-registry/devices` の tier を `"Advanced"` 固定 | サイズ導出をやめて固定 | Standard 化には delete + recreate が必要で、その間 mitamae と CI の fetch が全部失敗する。`lxc` の 4 キーは setup CI が SSM の値に対して型 assert するので落とせない |

**現在の構成（2026-08-31 LAN マップ実測）** — 巻き戻し判定の基準値

```
RTX1210    ac:44:f2:3a:2a:fd  192.168.1.253   HND
 └ SWX2100-5PoE  ac:44:f2:39:07:13  Rev.3.02.07  serial Z5101897WZ  poe_cap 700
     ├ port1  WLX402  ac:44:f2:49:5e:48  192.168.1.5   給電 6.3W
     └ port4  WLX323  f4:d5:80:1d:59:50  192.168.1.6   給電 9.6W  Rev.25.01.08
RTX830     ac:44:f2:64:d2:84  192.168.1.254   ITM
 └ SWX2110P-8G   ac:44:f2:09:f7:3d
     └ port1  WLX313  ac:44:f2:5a:d7:20  192.168.1.155
```

**残っている穴（未修正・未確認）** — 調査開始時に「ここは元から見えない / 直っていない」と分かっている項目

| 項目 | 状態 |
|---|---|
| Vector の `filter_re` が IPv4 専用（HND ログの 99.5% が未パース） | 未修正 |
| WLX313（ITM）が syslog を送っていない | 未修正の観測穴 |
| LXC 全台の journald が 2026-05-16 で停止（unbound / Vector のサービスログが ES に無い） | 未修正。原因**未特定**（Fleet の integration policy から journald input が外れた可能性が高いが**未確認**） |
| `logs-nginx.access-default` が 2026-05-10 で供給停止（2 本目の backing index は 0 docs のまま 4 か月） | 復活か廃止か未決 |
| `metrics-*` がスナップショット対象外（リンクフラップの唯一の 30 日ソースがバックアップされていない） | 未対応 |
| v6 QUIC 戻りの IN(11) reject 6〜8% | 受容中。恒久対策は plan mode + adversarial review 必須 |
| `rtx_access_list_ipv6_dynamic.source` に validator が無く、取り違えが plan にも apply にも現れない | TODO.md に起票済み |
| SFTP キャッシュ読みの同型 provider リソース（nat_masquerade / syslog / system / httpd / bridge / ipv6_* / nat_static / pptp / l2tp_service / admin / sshd） | 未監査（dns_server / dhcp_scope は v0.14.1、snmp_server は v0.15.0 で修正済み） |
| `[SWCTL]` で L2MS スイッチ 2 台が 34 秒周期で detect down を反復（各 2,512 件/日、7 日間 detect up ゼロ）。3 台とも devices.tf 未登録 | 所有者は ITM 側と判明済み、登録は未 |
| WLX323 の `nss_cryptoapi_ablk_setkey: Unable to allocate crypto session(-2)` 2,664 件（alert）/ `dp_me_update_mcast_table: msglen is less than hdrlen` 4,746 件（err）。wlx402 は両方 0 件 | 未解明。crypto session 枯渇は SSR の引き金ではないと実測で否定済み |
| WLX の status_code 126（627 件、wlx323 の 0102 のみ） | 意味**未確認** |
| Vector の `parse` transform で 1.32%（9,458/714,706）が落ちる内訳 | **未特定**（MAC ACL 行は parse を通るので、さらに別の未知の書式） |
| WLX402 の BSSID → バンド対応（`:50`/`:51`/`:52`/`:58`） | ES 単体で確定不能。§4.1 の telnet 手順が要る |
| HND SNMP に ITM の機器が L2MS 配下として見える（`ifDescr` に `RTX830_M5B102332:1`〜`:5`） | IPsec トンネル越しに L2MS が届いているのか物理配置なのか**未確認**。ITM 側の障害を HND のログで追えるかがこれで変わる |
| WLX の `show log` リングバッファの正確な容量（行数かバイト数か） | **未計測**。障害時ほどログ量が増えて保持が短くなるので、切り分けの前提として確定させる価値がある |
| WLX402 / WLX313 が SSM に自分名義のパスワードを持たず、`/wlx-aps/wlx323/admin_password` で認証が通る（2/2 実測） | 意図的な共有か登録漏れか**未確認** |
| ITM RTX830 の SSH 秘密鍵が SSM に無い / `external-memory config filename` を一度も確認していない | **未確認** |
| `system_profiler SPAirPortDataType` の 120 秒超ハングの原因 | **未確認**（無線スキャンとの競合と**推測**） |
| in チェーン参照時の `ipv6 filter dynamic` の src/dst 評価セマンティクス、`dhcp-prefix@lan2::/64` 記法の可否 | **未確認**（現在は `<コマンド> ?` probe が使える） |
| `pct set <id> --memory N` を先に当ててから `terraform apply -refresh-only` で state を合わせる回避策 | **未実測** |
| macOS/iOS が DHCPv6 の DNS を DHCPv4 の resolver と merge する挙動 | Apple 挙動として記載、**未実測** |
| WLX323 GUI の資格情報がどこにも記録されていない（SSM の admin_password は telnet 用で GUI は 401） | AP 設定変更が必要になった時点で詰む |

---

## 6. 出典

**メモリファイル** — `/home/shin1ohno/.claude/projects/-home-shin1ohno-ManagedProjects-home-monitor/memory/`（`MEMORY.md` が索引）

| ファイル | 本プレイブックでの参照箇所 |
|---|---|
| `rtx-dns-no-tcp.md` | §5.2 RTX DNS |
| `rtx-dns-resolver-and-provider-bug.md` | §5.1 provider read-back / §5.2 next-hop 転送 |
| `unbound-ct118-no-reply-incident.md` | §5.2 unbound wedge / §5.4 watchdog |
| `rtx-snmp-host-acl-terraform-managed.md` | §5.1 snmp_exporter / §5.4 SNMP ACL |
| `unbound-home-local-forward-wedge.md` | §5.1 canary / §5.2 forward wedge / §5.4 home.local |
| `air-private-wifi-mac-dhcp-trap.md` | §5.2 ランダム化 MAC |
| `air-dhcp-option61-clientid-bind.md` | §5.2 option 61 |
| `itm-syslog-template-drift.md` | §5.1 テンプレートドリフト / §5.4 |
| `aws-cost-baseline.md` | §5.1 ingest-drop |
| `rtx-hnd-save-usb-trap.md` | §5.2 save / §5.4 |
| `rtx-mac-acl-delete-implicit-deny.md` | §5.2 MAC ACL / §5.4 |
| `wlx323-wrong-ip-silent-syslog-drop.md` | §5.1 冒頭 / §5.4 .6 移設 |
| `cognee-109-lancedb-avx2-sigill.md` | （ネットワーク調査対象外） |
| `rtx-log-pipeline-findings-2026-08.md` | §5.1 filter_re / filter 番号 / §5.3 時計 |
| `rtx-v6-return-path-root-cause.md` | §5.2 in チェーン |
| `rtx-dynamic-filter-state-lies.md` | §5.1 plan 差分ゼロ / §5.2 apply フラッシュ |
| `link-flap-diagnose-by-duration.md` | §1.3 / §3 |
| `wlx323-wifi-module-lowpower-cycle.md` | §4.1 GUI 専用 / §5.2 WLX / §5.4 LLDP |
| `rtx-filter-nolog-and-targeted-apply.md` | §5.2 nolog / init -upgrade / -target |
| `host-registry-ssm-payload.md` | §5.2 SSM tier |
| `dhcpv6-dead-dns-and-vpc-dns64.md` | §5.2 DHCPv6 / DNS64 / §5.4 |
| `rtx-v6-dynamic-udp-30s-timeout.md` | §5.1 IPv6 match_phrase / §5.2 30s timeout |
| `pve-lxc-memory-change-reboots-ct.md` | §5.2 bpg provider |
| `rtx-console-probe-and-schedule-syntax.md` | §4.2 SSH / §5.1 show log grep / §5.3 時計 |
| `wlx323-6ghz-band-thrashing.md` | §4.2 /ap_config / §5.2 6GHz / §5.4 |

**リポジトリ内ドキュメント** — `/home/shin1ohno/ManagedProjects/home-monitor/`

- `docs/reports/2026-09-05-wlx323-6ghz-observation.md` — 6GHz 切替の観測レポート
- `docs/runbooks/tailscale-key.md` — Tailscale auth key のローテーション・復旧
- `docs/runbooks/pve-resize-provisioning.md` — PVE LXC のリサイズ
- `.claude/skills/codecommit-pr/` — PR 作成・マージ（`gh` は使えない）
- `.claude/skills/ec2-recovery/` — EC2 subnet-router の復旧
- `.claude/skills/host-registry-delivery/` — `contracts/devices.json` の SSM 配送

注: `docs/runbooks/wlx323-radio-stability.md` は**存在しない**（実測。`docs/runbooks/` には上記 2 本のみ）。

**setup リポジトリ** — `/home/shin1ohno/ManagedProjects/setup/`

- `cookbooks/lxc-monitoring/files/vector.toml` — syslog パース（`filter_re` は 137 行目）、送信元 IP マップ、disk buffer 設定
- `cookbooks/unbound/` — CT118 resolver、watchdog
- `cookbooks/ssh-keys/` — SSM からの鍵配布
