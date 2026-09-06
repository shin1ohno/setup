---
name: network-log-audit
description: |
  自宅ネットワーク（YAMAHA RTX ルータ 2 台・WLX 無線 AP 3 台）の不具合を ES のログから調査する skill。
  ログの参照先、どこまで遡れるか、実機 read-only probe、既知の罠、そして比較の作法
  （同一クロック窓ベースライン・分母の取り方・positive control）を持つ。
  `[self-heal] Net: ...` issue（source=network）を受けた self-heal-resolve の調査 recipe でもある。
  「WiFi が不安定」「ネットワークが切れる」「AP のログ調べて」「RTX のログ」「ネットワーク調査」
  「wlx323」「rtx-hnd」でトリガー。
  検知はしない（Kibana の `Net: *` ルールの責務）。実機は読み取りのみ、設定変更はしない。
user-invocable: true
---

# network-log-audit — RTX / WLX の不具合をログから調べる

**この skill は検知しない。**定期検知は `expected-network-signals.json` から生成される
Kibana の `Net: *` ルールが担い、発火は CT111 observer → `self-heal-state` → GitHub issue
（`shin1ohno/setup`、`self-heal` ラベル、`source: network`）へ自動で流れる。
この skill は**その issue を受けた深掘り**と、**手動調査**を担う。

## 不変の安全境界

1. **実機は読み取りのみ。** AP / RTX / スイッチの設定変更・再起動・save・config push・
   CONFIG 復元は一切しない。SFTP は `get` のみ（`put` 禁止）
2. **ES は GET のみ。** `_search` / `_cat` / `_cluster` / `_data_stream` / `_ilm` / `_snapshot`
3. **snapshot restore は本番クラスタへの書き込み。**提案するだけで、実行は承認を取る
4. **秘密情報を出力しない。** AP config の `airlink psk-key` は平文。行の存在だけ報告する
5. 修正が要ると判断したら**提案までで止める**。ネットワーク機器は remediation allowlist が空で、
   自動修正の対象外（class D = `self-heal-needs-human`）

## 30 秒で始める

不具合報告を受けたら、**窓の確定**と**パイプラインの生死**を先に押さえる。
ここを飛ばすと、後段の「0 件」が全部信用できなくなる。

```bash
PW=$(aws ssm get-parameter --name /monitoring/elastic/elastic-password --with-decryption \
      --profile sh1admn --region ap-northeast-1 --query Parameter.Value --output text)
ES=https://192.168.1.77:9200
Q() { curl -s -k -u "elastic:$PW" --max-time 60 "$ES/$1/_search" \
        -H 'Content-Type: application/json' --data-binary @-; }
```

**① 遡れる窓を確定する（ILM で毎日後退する。本調査中も 3 時間で 1 日ぶん消えた）**

```bash
curl -s -k -u "elastic:$PW" "$ES/.ds-logs-wlx-default-*/_ilm/explain?human" \
  | jq -r '.indices | to_entries[] | "\(.key) age=\(.value.age)"'
```

**② syslog が本当に届いているか（ES の 0 件を信じる前に）**

```bash
curl -s --max-time 8 http://192.168.1.76:9598/metrics \
  | grep -E 'vector_component_(received|sent|discarded)_events_total'
```

`component_id="parse"` の discarded が増えていたら Vector が送信元 IP マップ外を捨てている。

**③ 機器別の直近 24h 件数（母数を先に取る）**

```bash
echo '{"size":0,"track_total_hits":true,
 "query":{"range":{"@timestamp":{"gte":"now-24h"}}},
 "aggs":{"h":{"terms":{"field":"host","size":10}}}}' | Q 'logs-rtx-default,logs-wlx-default'
```

期待値: `.253`(RTX hnd) 15〜29 万 / `.254`(RTX itm) 100〜300 / `.5`+`.6`(WLX) 合計 1〜11 万。
`.155`(WLX313) は**構造的に 0**（既知の穴。`references/es-catalog.md`）。

## 比較の作法 — ここを外すと結論が反転する

2026-09 の 6GHz 調査では、この 8 点のどれかを外して**主要な所見を 6 回撤回した**。

1. **日内変動の大きい指標は同一クロック窓 × 複数日でベースラインを取る。**
   週平均レートとの比較は時間帯効果と交絡する。深夜に静かな端末は週平均比では常に「異常な沈黙」に見える
2. **バースト型指標の分母は時間ではなく機会の回数。**
   CCE 拒否は「45 分窓で 0 件」だと正常変動（過去 209 窓中 114 窓がゼロ）だが、
   AUTH 試行数を分母に取ると 37.68% → 0.00%（P≈3e-15）で決定的になる
3. **滞在の主従は回数ではなく滞在時間で測る。**
   再接続の多いバンドほど assoc 回数が水増しされ、主力バンドの判定が逆転する
   （回数では 5GHz(2) 46%、滞在時間では 5GHz(1) 68.3% が正解だった）
4. **「0 件」の前に positive control。**同じクエリ形が既知トークンで非ゼロを返すことを確認する
5. **集計ではなく端末別に見る。**AP 全体の切断数は範囲内でも、特定の 2 台に集中していることがある
6. **イベントは 1 件ずつ前後関係で分類する。**
   `<0124> Reason Code 1` を「AP が追い出した」と読んだが、実測 14 件すべてが
   「別 BSSID へ associate した直後 2 秒以内」＝ハンドオーバの後始末だった
7. **測る境界を明示する。**インタフェース DOWN→UP は 43 秒でも、
   端末から見た実効断は 5GHz で 109 秒だった（ACS が DFS チャンネルに着地し CAC 62 秒が乗る）
8. **変更直後の異常を変更のせいと決めない。未変更の対照を先に見る。**
   AP 設定変更の翌朝に始まった Mac の再接続ループは、**未変更の別 AP で先に始まっていた**。
   真因は端末のバッテリー残量 ≤9% でのクラムシェルスリープで、AP とは無関係だった

ベースラインの粒度にも注意する。2 時間刻み 30 スナップショットでは最大 3、
20 分刻み 144 スナップショットでは最大 4 になり、**粗いベースラインは偽の「範囲外」を作る**。

## `[self-heal] Net: ...` issue を受けたときの手順

1. issue body の `<!-- self-heal-source:network -->` と `dedup_key` から、どのルールが発火したかを特定する
2. **ルール名が診断の入口。**`expected-network-signals.json` の該当 signal の `message` に
   一次トリアージが書いてある（cookbooks/lxc-kibana/files/）
3. **アラートの `observed` は汎用文言なので、数値は自分で取り直す。**
   上の「比較の作法」に従い、同一クロック窓 × 過去 6 日のベースラインを添えて報告する
4. 実機の状態が要るなら `references/probes.md` の read-only probe を使う
5. **ネットワーク機器の修正は class D。**診断と提案を issue にコメントし、
   `self-heal-needs-human` を付けて止める。設定変更はしない

## 参照資料

| ファイル | 内容 |
|---|---|
| `references/es-catalog.md` | データストリーム一覧と答えられる問い、`logs-wlx` / `logs-rtx` のコード辞書、BSSID↔バンド対応、syslog が届いていない機器 |
| `references/retention.md` | 保持期間の実測、「n 日前 → どのソース」対応表、ILM が削る速度、S3 スナップショットからの復元手順 |
| `references/probes.md` | WLX telnet / RTX SSH・LAN マップ API・SFTP / 端末側 `pmset` / mDNS による機種同定。すべて read-only |
| `references/pitfalls.md` | 観測パイプラインが嘘をつくケース、機器・プロトコル固有の罠、時計とタイムスタンプ、恒久対処と巻き戻し条件 |

関連: `home-monitor/docs/runbooks/wlx323-radio-stability.md`（SSR 障害の runbook と巻き戻し条件）、
`home-monitor/docs/reports/2026-09-05-wlx323-6ghz-observation.md`（6GHz 切替の全観測）、
`home-monitor/scripts/wlx-band-change-compare.sh`（設定変更前後の比較スクリプト）。
