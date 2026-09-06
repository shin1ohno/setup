# 実機 read-only probe カタログ

WLX telnet / RTX SSH・LAN マップ API・SFTP / 端末側 pmset / mDNS による機種同定。すべて読み取り専用。

as-of 2026-09-06。数値はすべて実測で、母数と窓を添えてある。
このファイルは `network-log-audit` skill の参照資料。実機は読み取りのみ。

---

## 4. 実機 read-only probe カタログ

到達性（実測 TCP connect、2026-09-06）:

| 機器 | IP | 22/SSH | 23/telnet | 80/HTTP | 一次 probe |
|---|---|---|---|---|---|
| WLX323 (HND) | 192.168.1.6 | 閉 | **開** | 開 | telnet |
| WLX402 (HND) | 192.168.1.5 | 閉 | **開** | 開 | telnet |
| WLX313 (ITM) | 192.168.1.155 | 閉 | **開** | 開 | telnet |
| RTX1210 (HND) | 192.168.1.253 | **開** | 開 | **開** | SSH + LAN マップ API |
| RTX830 (ITM) | 192.168.1.254 | 開 | 開 | 開 | SSH（鍵は SSM 未登録） |

**WLX は SSH を持たない。**AP に入る経路は telnet 23 のみ。

資格情報はすべて SSM。ファイルに置かない。

```bash
export AWS_PROFILE=sh1admn AWS_REGION=ap-northeast-1

# WLX 全 3 台で共通（実測: .6 の値で .5 / .155 とも login=OK）
AP_PW=$(aws ssm get-parameter --name /wlx-aps/wlx323/admin_password \
  --with-decryption --query Parameter.Value --output text)

# RTX1210 SSH 秘密鍵（使用後に shred）
aws ssm get-parameter --name /rtx-routers/hnd/ssh/private_key \
  --with-decryption --query Parameter.Value --output text > ~/.ssh/rtx_hnd_key
chmod 600 ~/.ssh/rtx_hnd_key

# RTX1210 HTTP (LAN マップ API) の Basic 認証
RTX_PW=$(aws ssm get-parameter --name /rtx-routers/hnd/user_password/shin1ohno \
  --with-decryption --query Parameter.Value --output text)
```

実在する SSM パラメータ（18 本）のうち AP 系は `/wlx-aps/wlx323/admin_password` の 1 本のみ。RTX 系は `/rtx-routers/{hnd,itm}/` 配下に `admin_password` / `ipsec_psk` / `sftp/{username,password}` / `ssh/{private,public}_key` / `user_password/shin1ohno`。ITM は SSH 秘密鍵が無く、`sshpass` + `user_password/shin1ohno`。GUI 用の資格情報はどこにも記録がない（**未確認**）。

### 4.1 WLX (AP) telnet

**ログイン手順**（ユーザ名は聞かれない）: 接続 → `Password:` に管理パスワード → 非特権 `>` → `administrator` → 再び `Password:` に**同じパスワード** → 特権 `#`。

**汎用ランナー（`wlx_cmd.py`）**

```python
#!/usr/bin/env python3
"""WLX AP telnet one-shot runner (read-only).
usage: wlx_cmd.py <ip> "<cmd1>" "<cmd2>" ...
password: env WLX_PW, else SSM /wlx-aps/wlx323/admin_password
"""
import os, re, socket, subprocess, sys, time

IP = sys.argv[1]; CMDS = sys.argv[2:]
PW = os.environ.get("WLX_PW") or subprocess.check_output(
    ["aws","ssm","get-parameter","--name","/wlx-aps/wlx323/admin_password",
     "--with-decryption","--query","Parameter.Value","--output","text"],
    env={**os.environ,"AWS_PROFILE":"sh1admn","AWS_REGION":"ap-northeast-1"},
).decode().strip()

s = socket.create_connection((IP, 23), timeout=20)

def rd(idle=3.0, maxwait=180):
    """プロンプト(# / >) か Password: まで読む。---more--- には SPACE を送る"""
    s.settimeout(idle); acc = b""; t0 = time.time()
    while time.time() - t0 < maxwait:
        try: d = s.recv(65535)
        except socket.timeout: break
        if not d: break
        acc += d
        if b"---more---" in acc[-60:]:
            s.sendall(b" "); continue        # ページャは SPACE で次ページ
        if acc.rstrip()[-1:] in (b"#", b">") or acc.endswith(b"Password: "):
            break
    return acc

def wr(x): s.sendall(x.encode() + b"\r\n"); time.sleep(0.4)

rd(3); wr(""); rd(1); wr(PW); rd(2)          # Password:
wr("administrator"); rd(1); wr(PW); rd(3)    # 昇格

for c in CMDS:
    print("\n===== %s :: %s =====" % (IP, c))
    s.sendall(c.encode() + b"\r\n"); time.sleep(0.4)
    txt = rd(4.0, 240).decode("utf-8", "replace")
    print(re.sub(r"---more---\s*(\x08| )*", "", txt))
try: s.sendall(b"exit\r\n")
except Exception: pass
```

**コマンド一覧の取り方**: `show ?` は 9 語しか返さない（`? airlink arp command config copyright environment log status techinfo`）。**全コマンドの網羅列挙は `show command`**（説明文つき）。

```bash
python3 wlx_cmd.py 192.168.1.6 "show command"       # 全コマンド + 説明
python3 wlx_cmd.py 192.168.1.6 "show airlink ?"     # -> station のみ
python3 wlx_cmd.py 192.168.1.6 "show status ?"      # -> airlink boot dhcp dhcpc lan1:1
                                                    #    radiusd vlan wlan-controller yno cluster
```

**`show environment` — 筐体状態とログ地平線**

```
WLX323 Rev.25.01.08 (Mon Jun 08 20:28:21 2026)
  main:  WLX323 ver=01 serial=Z8E02337DZ
MAC-Address=f4:d5:80:1d:59:50, f4:d5:80:1d:59:58,
            f4:d5:80:1d:59:60, f4:d5:80:1d:59:68
CPU:  15%(5sec)  13%(1min)  13%(5min)    Memory: 38% used
Boot time: 2026/08/29 17:39:34 +09:00
Elapsed time from boot: 7 days 19:02:40
Inside  Temperature(C.): 53.5
Power: PoE(30W)
```

MAC が 4 本出るのが要点。`:50` が本体、`:58`/`:60`/`:68` が各無線モジュールの BSSID で、syslog の `| AP <bssid>` と突き合わせて帯域を特定する。

**`show status airlink module` — モジュール→帯域→BSSID**

| MODULE | 周波数 | BSSID | Tx-Power |
|---|---|---|---|
| 1 | 2.412 GHz (2.4G) | `f4:d5:80:1d:59:58` | 21 dBm |
| 2 | 5.66 GHz (ch132) | `f4:d5:80:1d:59:60` | 22 dBm |
| 4 | **6.135 GHz (6G)** | `f4:d5:80:1d:59:68` | 19 dBm |

**MODULE 3 は出てこない** — 欠番ではなく「5GHz(2) が無効」。`Rx invalid nwid` / `Rx invalid crypt` / `Missed beacon` も同時に出る。

**`show airlink station list` — 接続端末の電波品質**

カラム: `ADDR CHAN TXRATE RXRATE RSSI MINRSSI MAXRSSI IDLE ASSOCTIME TXRETRY RXRETRY` + 各行下の詳細ブロック。

```
58:d3:49:35:21:7d  CHAN 1  65M/72M  RSSI -50 (MIN -66 / MAX -40)
  IDLE 0  ASSOCTIME 14:11:17  TXRETRY 329216  RXRETRY 0
  SNR: 52   Operating band: 2.4GHz
  Channels supported : 2412 2417 ... 2472
  Throughput: 50 Kbps, Max: 2318 Kbps
```

`Channels supported` は**端末が申告した対応チャンネル**なので、AP 側から端末の帯域能力を推定できる（確定は §4.3）。**`MINRSSI` を見ること** — 瞬間 RSSI が -50 dBm でも最低 -66 dBm まで落ちていることがある。

**`show log` — AP 内蔵ログ**

```
2026/08/29 16:53:06: [80211] <0101> Received AUTH REQ from STA (3c:0a:f3:a1:64:6c). | AP <f4:d5:80:1d:59:58>
```

全文ダンプは非現実的（540 秒上限のスクリプトで 5,972 行 = 72 分ぶんが限界）。2026-08-17 以降は syslog が ES に入るので、**履歴は ES、`show log` は直近と ES 欠損期間の穴埋め**に使い分ける。遡及範囲は §2.4。

**`show config` の二重構造（6GHz を触る前に必読）**

| 行 | 節 | 定義される module |
|---|---|---|
| 1–65 | **device-local**（AP 単体設定） | module1 / module2 / module3 |
| 66–113 | **`wlan-controller select 1`**（コントローラ管理） | module1 / module2 / module3 / **module4** |

**module4（6GHz）は `wlan-controller select 1` 節にしか存在しない。**device-local 節だけを見ると「6GHz は未設定」と誤読する。**コントローラ節が正本。**

ZIP コンフィグのヘッダがハード構成を申告する: `# Wireless Modules: module1=2.4GHz module2=5GHz(1) module3=5GHz(2) module4=6GHz(1)`。つまり module3 は 5GHz の 2 本目。

**罠**

| やりがち | 実際 | 正解 |
|---|---|---|
| `show logging` | `Error: Invalid command name` | `show log` |
| `console lines infinity` | `Error: Invalid command name`（**RTX にはあるが WLX には無い**） | ページャに SPACE を送る |
| `---more---` を無視 | 出力が途中で止まる | SPACE (`0x20`) を送る |
| 放置 | Login Timer で切断 | 1 セッションに用件をまとめる |
| CLI で無線/LLDP を変更 | CLI に設定コマンドが無い（GUI 専用） | 本カタログは read-only なので対象外 |

### 4.2 RTX SSH / LAN マップ API / SFTP

**SSH は exec channel を持たない。`-tt` で PTY を張り、1 行ずつ流し込む。**

```bash
ssh -i ~/.ssh/rtx_hnd_key shin1ohno@192.168.1.253 "show environment"
# -> exec request failed on channel 0
```

```bash
{ sleep 3; echo "console lines infinity";
  sleep 1; echo "show status dhcp summary";
  sleep 5; echo "exit"; sleep 2; } \
| ssh -tt -i ~/.ssh/rtx_hnd_key \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      shin1ohno@192.168.1.253 2>&1
```

**`console lines infinity` は RTX では有効**（WLX には無い）。最初に送ればページャを無効化できる。

補足: 行終端は CR のみ（`\r\n` はパスワードプロンプトに空行を食わせる）。バナー直後の 1 コマンド目は取りこぼすことがあるので、確実に読みたいものは 2 番目以降に置く。接続は **IPv4 で**（`hnd.home.local` は ULA に解決され `Error: Login access is restricted.`）。RSA 鍵なら `-o PubkeyAcceptedKeyTypes=+ssh-rsa -o HostKeyAlgorithms=+ssh-rsa`。PTY 幅を 512 で要求しても 80 桁で折り返すので、長い設定行は de-wrap が要る。

**`<コマンド> ?` はファーム自身の入力形式を印字する（read-only）。**ドキュメントや記憶より確実。例: `schedule at ?` → `schedule at ID [日付] 時刻 * コマンド...`（実行コンテキストトークン `*` / `pp N` / `tunnel N` / `switch <sw>` が必須と分かる）。管理者モードが要るコマンドは `administrator` の後で。

**`show status dhcp summary` — MAC → IP → ホスト名**（端末同定の一次 probe）

```
  8:      192.168.1.30:  12:1f:94:f6:de:ea, Mac
 26:      192.168.1.49:  9c:58:84:16:a5:b2, ShinichOhnosAir
 37:      192.168.1.66:  58:d3:49:35:21:7d, Living-Room-2
```

**第 2 桁が 2/6/A/E の MAC はローカル管理アドレス**（Apple の Private Wi-Fi Address 等）で、ホスト名も `Mac` / `iPhone` / `Watch` のような汎用値になる → §4.4 の mDNS へ進む。

**`show arp` — 物理ポート attribution**

```
インタフェース IPアドレス        MACアドレス       TTL(秒)
LAN1(port4)    192.168.1.6       f4:d5:80:1d:59:50 1085
LAN1(port5)    192.168.1.10      00:3e:e1:c3:54:b5 1011
```

無線クライアントはすべて PoE スイッチ上流の `LAN1(port4)` に出る。

**`show status lan1` — 物理層とエラーカウンタ**

```
PORT1: Auto Negotiation (100BASE-TX Full Duplex)
PORT3: Auto Negotiation (1000BASE-T Full Duplex)
PORT7: Auto Negotiation (Link Down)
受信オーバーフロー:  25366
未サポートパケットの受信: 10590102
```

**`show log | grep …` はこの経路では使えない** — 出力が巨大で、RTX 側 grep が返る前に drain 窓が閉じ、**マッチ 0 件と区別がつかない空文字**が返る（2026-09-06 に `grep 2026` の positive control が空を返して判明）。ログは ES 側で引く。

`show config 0` は CONFIG0 のログイン/管理パスワードを対話で聞く（ログインユーザの SSM パスワードでは通らない）。保存済み設定は SFTP `get /system/config0`。

**LAN マップ API — AP に入らずチャンネル・PoE・ファームを読む**

AP の Login Timer や telnet セッション数を消費しない。

```bash
# トポロジ一覧
curl -s -u "shin1ohno:$RTX_PW" \
  "http://192.168.1.253/lan_map/lan_map_data_init.json?lan_no=1&page=1"
```

実測 7 ノード（`route` が物理トポロジ）:

| model | device_name | ip | route | serial |
|---|---|---|---|---|
| RTX1210 | RTX1210_Ebisu | .253 | `root` | — |
| SWX2100-5PoE | SWX2100-5PoE_Z5101897WZ | — | `lan1:4` | Z5101897WZ |
| WLX402 | WLX402_HND | .5 | `lan1:4-1` | Z4V01475YI |
| **WLX323** | WLX323_HND | .6 | **`lan1:4-4`** | Z8E02337DZ |
| RTX830 | RTX830_M5B102332 | .254 | `lan1:6` | M5B102332 |
| SWX2110P-8G | SWX2110P-8G_Z7K01199CX | — | `lan1:6-lan1:1` | Z7K01199CX |
| WLX313 | WLX313_Z5F03220VP | .155 | `lan1:6-lan1:1-1` | Z5F03220VP |

```bash
# 機器詳細（チャンネル・ファーム・PoE）
curl -s -u "shin1ohno:$RTX_PW" \
  "http://192.168.1.253/lan_map/lan_map_data_from_mac.json?lan_no=1&addr=f4:d5:80:1d:59:50&update=0"
```

```
model        = WLX323          serial   = Z8E02337DZ
revision     = Rev.25.01.08 (Mon Jun 08 20:28:21 2026)
power_supply_string = PoE
airlink[0] channel = 1                   bandwidth = 20    # 2.4GHz
airlink[1] channel = 132+136+140+144     bandwidth = 80    # 5GHz
airlink[2] channel = 47                  bandwidth = 160   # 6GHz
```

`airlink[]` は 0=2.4G / 1=5G / 2=6G で、`show status airlink module` の MODULE 1 / 2 / 4 に対応。

```bash
# PoE 給電電力（スイッチの MAC を指定。単位は 0.1 W）
curl -s -u "shin1ohno:$RTX_PW" \
  "http://192.168.1.253/lan_map/lan_map_data_from_mac.json?lan_no=1&addr=ac:44:f2:39:07:13&update=0" \
| python3 -c "
import json,sys; o=json.load(sys.stdin)['success']['own']
for i,p in enumerate(o['ports']):
    print(f\"port{i+1}: supply={p.get('status_supply')} state={p.get('status_poe_state')} {p.get('status_speed_string')}\")"
```

実測（SWX2100-5PoE、Rev.3.02.07）: port1 = 63（6.3 W、WLX402）/ port4 = 98（**9.8 W**、WLX323）/ `status_supply_total` = 161（16.1 W）。6.3 + 9.8 = 16.1 で合計と一致するので**単位は 0.1 W**と確定。`status_poe_state` は 6 = 給電中 / 1 = 非給電。

**罠**: `poe_class_string` が `給電しない` と表示されても、これは設定値。実際の給電は `status_supply` を見る。スイッチ側 JSON に **LLDP 設定のフィールドは無い**（`basic_*` / `poe_*` / `loop_detect_*` / `eco` のみ）。

**SFTP — `/ap_config` の AP コンフィグ回収**

```bash
sftp -i ~/.ssh/rtx_hnd_key shin1ohno@192.168.1.253 <<'EOF'
ls -l /ap_config
get /ap_config/f4_d5_80_1d_59_50.conf
bye
EOF
```

ファイル名は AP の MAC。**ただしファイル名と中身は一致しない。復元前に必ずヘッダを読む。**

```bash
file <conf>          # Zip archive data / ASCII text の判別

# ZIP なら内部 config/config.txt の先頭 6 行が正体を明かす
python3 -c "
import zipfile,sys
z=zipfile.ZipFile(sys.argv[1])
n=[x for x in z.namelist() if x.endswith('config.txt')][0]
print('\n'.join(z.read(n).decode('utf-8','replace').splitlines()[:6]))" <conf>
```

実測: `f4_d5_80_1d_59_50.conf`(31,303 B) = WLX323 の ZIP、`ac_44_f2_49_5e_48.conf`(3,611 B) = WLX402 の**平文テキスト**、`ac_44_f2_5a_d7_20.conf`(26,976 B) = **WLX313 = ITM（別拠点・別機種）の ZIP**。前回セッションが「402」と名付けて回収したファイルの中身は WLX313 だった。平文側は `# 機種名 Rev.` が無く `#17 0 16 0` で始まり、`system name WLX402_HND` で判別する。

**取り扱い注意**: ZIP には `config/certs/server.key` `ca.key`（TLS 秘密鍵）が含まれ、`airlink psk-key` は**平文**で入っている。展開先を放置しない。

### 4.3 端末側（macOS）

**AP 側のログには端末がスリープした理由が一切残らない。**端末発の切断（`0117` / `0125`）を追うときは必ずこちらを取る。

**`pmset -g log` — スリープ/ウェイクの原因**

実測 81,396 行 / 24 MB / 生成 7 秒、保持は約 7 日（ES の ILM とほぼ同じ窓）。**必ず一度ファイルに落としてから grep する**（毎回生成すると 24 MB を何度も転送し 60 秒 timeout を割る — 実測で 1 回失敗）。

```bash
ssh sh1@192.168.1.30 'pmset -g log > /tmp/pml.txt; \
  echo "lines=$(wc -l </tmp/pml.txt) bytes=$(wc -c </tmp/pml.txt)"'

# スリープ原因のヒストグラム（本命）
ssh sh1@192.168.1.30 \
  "grep -E '^[0-9]{4}-.* Sleep  ' /tmp/pml.txt \
   | sed -E \"s/.*Sleep  +//; s/ *:.*//; s/[0-9]+//g\" \
   | sort | uniq -c | sort -rn"
```

実測（7 日窓）: `Maintenance Sleep` 2,539 / `Sleep Service Back to Sleep` 230 / **`Clamshell Sleep` 65** / `Notification Wake Back to Sleep` 4。この 65 件が、AP 側では「端末が勝手に切れた」としか見えない事象の正体。

```bash
ssh sh1@192.168.1.30 "grep -E '^[0-9]{4}-.* (Sleep|Wake|DarkWake) ' /tmp/pml.txt | tail -20"
```

各行に `Using AC (Charge:18%)` が付くので、**バッテリー残量と切断の相関がこの 1 コマンドで取れる**。

**`system_profiler SPAirPortDataType` — 6GHz 対応可否の確定**

```bash
ssh sh1@192.168.1.30 'timeout 180 system_profiler SPAirPortDataType > /tmp/spa.txt'

# 対応チャンネルを帯域別に数える（6GHz 可否の答え）
ssh sh1@192.168.1.30 \
  'grep "Supported Channels:" /tmp/spa.txt | tr "," "\n" \
   | grep -oE "\(([0-9]+)GHz\)" | sort | uniq -c'
```

実測（192.168.1.30 = Mac14,2 / MacBook Air M2）: `26 (2GHz)` / `40 (5GHz)` = **6GHz 0 本、合計 66 本**。`Supported PHY Modes: 802.11 a/b/g/n/ac/ax`（`be` 無し）とも整合。この端末は 6GHz に上がれない — 電波状況や AP 設定ではなくハードウェア能力の問題。2GHz/5GHz が非ゼロで返ることがこの 0 件の positive control になっている。

同ファイルから現在のリンク状態も読める:

```
MAC Address: 12:1f:94:f6:de:ea      <- DHCP の Private MAC と一致
Current Network Information:
  ohno: PHY Mode: 802.11ax / Channel: 132 (5GHz, 80MHz)
        Security: WPA3 Personal / Signal / Noise: -64 dBm / -90 dBm
Other Local Wi-Fi Networks:
  6BCB0802-5G: Channel 108 (5GHz, 160MHz)  -81 dBm   <- 近隣 AP の干渉源
  TP-Link_A9F2: Channel 48 (5GHz, 80MHz)   -83 dBm
```

`Other Local Wi-Fi Networks` は近隣 AP のスキャン結果なので、チャンネル干渉の調査にそのまま使える。

**罠**: 通常 3 秒だが **120 秒超のハングを 1 回観測**（原因**未確認**、無線スキャンとの競合と**推測**）。`timeout` 必須 + リトライ。

**その他**

```bash
ssh sh1@192.168.1.30 'pmset -g ps'   # Now drawing from 'AC Power' / -InternalBattery-0 18%; charging
ssh sh1@192.168.1.30 \
  'ioreg -rn AppleSmartBattery | grep -E "CurrentCapacity|MaxCapacity|CycleCount|ExternalConnected|IsCharging"'
```

### 4.4 mDNS による端末同定

プライベート MAC（第 2 桁 2/6/A/E）の端末は OUI からベンダも引けず、DHCP ホスト名も汎用。5353 にマルチキャストで問い合わせると `model=` / `osxvers=` が取れる。

```python
#!/usr/bin/env python3
# usage: mdns_probe.py            -> LAN 全体（positive control 兼用）
#        mdns_probe.py <ip>       -> 特定ホストのみ
import socket, struct, time, re, sys
LOCAL = '192.168.1.64'          # ← 自ホストの LAN IP に変える
TARGET = sys.argv[1] if len(sys.argv) > 1 else None
MC = '224.0.0.251'

def enc(n): return b''.join(bytes([len(p)])+p.encode() for p in n.split('.') if p)+b'\x00'
def q(n, t=12): return struct.pack('>HHHHHH',0,0,1,0,0,0)+enc(n)+struct.pack('>HH',t,1)

r = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
r.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try: r.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
except Exception: pass
r.bind(('', 5353))              # 5353 に bind しないと応答を受けられない
r.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
             struct.pack('4s4s', socket.inet_aton(MC), socket.inet_aton(LOCAL)))
r.settimeout(8)

sd = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sd.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
for n in ["_raop._tcp.local", "_airplay._tcp.local", "_companion-link._tcp.local",
          "_rdlink._tcp.local", "_device-info._tcp.local",
          "_services._dns-sd._udp.local"]:
    sd.sendto(q(n), (MC, 5353)); time.sleep(0.2)

t0 = time.time(); by = {}
while time.time() - t0 < 10:
    try: d, a = r.recvfrom(9000)
    except Exception: break
    if TARGET and a[0] != TARGET: continue
    by.setdefault(a[0], []).append(d)

print("応答ホスト数 =", len(by))
for ip in sorted(by, key=lambda x: tuple(map(int, x.split('.')))):
    s = set()
    for d in by[ip]:
        for m in re.finditer(rb'[\x20-\x7e]{4,63}', d): s.add(m.group(0).decode())
    tags = [x for x in sorted(s) if x.startswith(('model=', 'osxvers=', 'srcvers=', 'deviceid='))]
    print(f"  {ip:15s} pkts={len(by[ip]):3d} {tags[:4]}")
```

実測（LAN 全体、22 ホストが応答）:

| IP | model | osxvers | 判定 |
|---|---|---|---|
| 192.168.1.25 | `Macmini9,1` | 26 | Mac mini M1 |
| 192.168.1.26 | `Macmini9,1` | 26 | Mac mini M1 |
| **192.168.1.30** | **`Mac14,2`** | **26** | **MacBook Air M2** |
| 192.168.1.51 | `AudioAccessory5,1` | — | HomePod |
| 192.168.1.66 | `AudioAccessory5,1` / `B520AP` | — | HomePod |
| 192.168.1.82 | `Mac17,5` | 25 | Mac |

DHCP で `Mac` としか出なかった `.30` が `Mac14,2` と確定し、§4.3 の「6GHz 非対応」と整合した。

**罠: 1 回の 0 件を信じない。**`.30` を単独指定した初回は 0 パケットだったが、直後に LAN 全体で流したら 9 パケット返した（端末が Maintenance Sleep 中だと無応答）。**必ず全ホスト版を先に流して positive control（応答ホスト数 > 0）を取り、対象が出ないときは時間を置いて 2〜3 回リトライする。**

補助: AirPlay ポートによる推定。

```bash
for p in 5000 7000; do timeout 3 bash -c "</dev/tcp/192.168.1.30/$p" \
  2>/dev/null && echo "$p OPEN" || echo "$p closed"; done
```

5000 / 7000 が開いていれば AirPlay レシーバ（Apple TV / HomePod / Mac）。

---
