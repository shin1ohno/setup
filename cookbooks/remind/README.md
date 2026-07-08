# remind

macOS Reminders にコマンドライン／ネットワーク越しで TODO を登録するツール。2 バイナリ構成。

- **`remind`** — ローカル CLI（Swift + EventKit、swiftc 単一ファイル）。全 Mac に配布。
- **`remindd`** — HTTP daemon（Swift + Hummingbird、SPM）。**Mac mini 限定・opt-in**。他マシンから LAN 越しに登録するためのもの。

## CLI（`remind`）

```
remind "タスク名"                                        # 既定リストへ
remind "見積り提出" --list Inbox --due "2026-07-09 10:00" --notes "詳細"
remind --lists                                           # リスト一覧
```

期日は `YYYY-MM-DD HH:MM`（時刻ありは alarm 付き）または `YYYY-MM-DD`。

## daemon（`remindd`）

`remindd serve` が HTTP/JSON を待ち受け、他マシンからの POST で Mac の Reminders に登録する。CLI とは別バイナリ・別ビルド（Hummingbird は依存 ~20・初回ビルド 2-5 分）なので、CLI しか使わない Mac には入れず、**opt-in した 1 台**（想定: 常時起動の自宅 Mac mini）だけで動かす。

### セキュリティ姿勢

- **LAN bind + Bearer token（平文 HTTP）**。据え置き・信頼 LAN 常駐の Mac mini 前提。残留リスクは「自宅 LAN 上で token/本文が平文」の 1 点（信頼 LAN + 個人 reminder で許容）。
- **持ち歩き laptop では有効化しない**。`0.0.0.0` bind は端末が繋いだ未信頼ネットワーク全てに daemon を晒す。
- `0.0.0.0` は loopback だけでなく **全インターフェース**（Tailscale `utun*` / Docker bridge 含む）で待ち受ける。Tailscale 稼働時は tailnet 全体に見える点に留意。特定 LAN IP に絞るなら `REMIND_BIND` を設定。
- **絶対にルータで 8787 をポートフォワードしない**（平文 token がインターネットに漏れる）。UPnP/NAT-PMP も要確認。
- token 漏洩時のローテーション: `rm ~/.config/remind/token` → `mitamae local darwin.rb`（再生成）→ `launchctl kickstart -k gui/$(id -u)/be.ohno.remindd`。全クライアントに新 token 再配布。

### 前提（mini 側）

1. Swift 6.1+ toolchain（Xcode CLT か Xcode）
2. **GUI(Aqua) ログインセッション**（auto-login 推奨）。LaunchAgent + TCC Reminders はユーザ GUI セッション束縛。headless SSH のみでは Reminders 権限が下りず、daemon は create 系を 503 で返し続ける。
3. 初回 `remindd` 起動時の Reminders full-access TCC プロンプトを mini の GUI で承認

### 有効化手順（mini）

```
touch ~/.config/remind/daemon-enabled          # opt-in マーカ
mitamae local darwin.rb                         # build + token 生成 + LaunchAgent 起動
# GUI で Reminders アクセスを承認
launchctl print gui/$(id -u)/be.ohno.remindd    # running 確認
cat ~/.config/remind/token                       # クライアントに配布する token
```

### API

```
POST /v1/reminders     Authorization: Bearer <token>
GET  /v1/lists         Authorization: Bearer <token>
GET  /healthz          (認証なし)

POST body (application/json):
{
  "title":    "見積り提出",            // required, 非空, <=1024
  "list":     "Inbox",                 // optional, 既定リスト
  "notes":    "詳細",                  // optional, <=16384
  "due":      "2026-07-09T10:00:00",   // optional ISO8601 / YYYY-MM-DD, 時刻ありは alarm
  "priority": 5,                       // optional 0..9
  "url":      "https://..."            // optional, http(s) のみ, <=2048
}
201 → {"id":"...","title":"...","list":"Inbox"}
400 (入力不正) / 401 (認証) / 404 (list 不明) / 503 (Reminders 未許可)
```

### クライアント例（別 LAN マシン）

```
TOKEN=$(...)      # mini の ~/.config/remind/token の値
curl -sS -X POST http://<mini-lan-ip>:8787/v1/reminders \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"title":"牛乳を買う","list":"Inbox","due":"2026-07-09T18:00:00"}'
```

## 既知の制限

接続 idle timeout / 同時接続数上限は未設定（slowloris hardening）。信頼 LAN 前提で今回スコープ外、`TODO.md` に追跡エントリあり。
