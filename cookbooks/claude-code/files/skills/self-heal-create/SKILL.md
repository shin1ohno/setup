---
name: self-heal-create
description: |
  self-heal observability ループの Layer 2-A（issue 作成）。CT111 observer が ES の
  self-heal-state インデックスに書く open/resolved 状態を読み、shin1ohno/setup の GitHub
  issue と同期する。ES で open かつ未 issue のものを issue 化、ES で消えたものを close + comment。
  読み取り専用（ES への書き込みなし・コード変更なし・PR なし）。冪等で、何度回しても差分のみ反映。
  「self-heal create」「self-heal issue を立てる」「fleet alert を issue 化」「self-heal 同期」でトリガー。
  対は self-heal-resolve（issue を解決する loop）。
user-invocable: true
---

# self-heal-create — fleet alert → GitHub issue 同期ループ

CT111 observer（`cookbooks/self-heal-observer`）が Kibana の alerts-as-data から検知し、
ES `self-heal-state` に書いた状態を、`shin1ohno/setup` の GitHub issue に同期するだけの薄い loop。
**検知はしない**（observer の責務）。**修正もしない**（self-heal-resolve の責務）。
GitHub issue 化することで「メール通知」と「作業ログ（コメント）」が無料で手に入る。

設計: `docs/self-heal-github-issues-plan.md`、`~/self-heal-observability-loop-design.md`（Layer 2）。

## 不変の安全境界（常に守る）

1. **read-only**: ES `self-heal-state` は GET のみ。ES に書き込まない（書くのは observer）。
2. **対象は `shin1ohno/setup` の `self-heal` ラベル issue のみ**。他リポ・他ラベルに触れない。
3. **コードを触らない・PR を作らない・merge しない**。issue の open/close と comment だけ。
4. **marker の無い issue に触れない**: body に `<!-- self-heal-key:... -->` が無い issue は対象外
   （手動で立てた self-heal ラベル issue を壊さない）。
5. **`self-heal-needs-human` ラベルが付いた open issue は close しない**（人間が見るべき状態）。
6. ES 到達不可・elastic pw 取得不可なら **何もせず STOP**（誤って全 issue を close しない）。

## 設定（env で上書き可、既定値は home fleet）

| 変数 | 既定 |
|---|---|
| `SELF_HEAL_REPO` | `shin1ohno/setup` |
| `SELF_HEAL_LABEL` | `self-heal` |
| `SELF_HEAL_ES_HOSTS` | `https://es-0.home.local:9200 https://es-1.home.local:9200 https://es-2.home.local:9200` |
| `SELF_HEAL_ES_CA` | `/etc/elastic-agent/certs/ca.crt` |
| `SELF_HEAL_ELASTIC_PW_SSM` | `/monitoring/elastic/elastic-password` |
| `SELF_HEAL_AWS_PROFILE` | `pve-bootstrap-ssm` |
| `SELF_HEAL_AWS_REGION` | `ap-northeast-1` |
| `SELF_HEAL_STATE_INDEX` | `self-heal-state` |

marker は `dedup_key` の sha1: `<!-- self-heal-key:$(printf '%s' "$dedup_key" | sha1sum | cut -d' ' -f1) -->`。
observer が ES doc `_id` に使う sha1 と同じ式なので、issue ↔ ES doc が 1:1 で対応する。

## 手順

### Step 0. 前提取得（失敗したら STOP）

```bash
ES_PW=$(aws ssm get-parameter --name "${SELF_HEAL_ELASTIC_PW_SSM:-/monitoring/elastic/elastic-password}" \
  --with-decryption --query 'Parameter.Value' --output text \
  --profile "${SELF_HEAL_AWS_PROFILE:-pve-bootstrap-ssm}" --region "${SELF_HEAL_AWS_REGION:-ap-northeast-1}" 2>/dev/null)
[ -n "$ES_PW" ] && [ "$ES_PW" != "None" ] || { echo "elastic pw 取得不可 — STOP"; exit 0; }
```

es-0→es-1→es-2 の順に fallback して GET する `es_get()` を使う（1 ホスト失敗で諦めない。全滅なら STOP）。
TLS は **`curl --cacert "$SELF_HEAL_ES_CA"` で検証できる**（pro-dev / CT111 とも確認済み）。`-k`
（証明書検証スキップ）は使わない — `--cacert` が通らない場合は CA パス/到達性の問題として STOP し調査する。

### Step 1. ES の open 集合を取得（真実源）

```bash
# status:open の dedup_key と表示用フィールド
es_get "/self-heal-state/_search" \
  '{"size":1000,"query":{"term":{"status":"open"}},
    "_source":["dedup_key","source","severity","observed_value","first_seen","host","service"]}'
```

`hits.hits[]._source` から `{dedup_key, source, severity, observed_value, first_seen, host, service}` を集める。
各 `dedup_key` の sha1 を計算（= marker key）。

**dedup_key の妥当性ガード（必須）**: `dedup_key` が **空文字列・JSON `null`・リテラル文字列 `"null"`・空白のみ**のいずれかの doc は **skip**（issue を作らない）。`jq` 抽出は `select(.dedup_key != null and (.dedup_key|tostring|gsub("^\\s+|\\s+$";"")) != "" and .dedup_key != "null")` で弾く。これを怠ると `[self-heal] null` のような無効 issue が作られる（観測済み: malformed/部分書き込みの self-heal-state doc 由来）。skip した doc は件数だけログに残す。

### Step 2. GitHub の open self-heal issue を取得

```bash
gh issue list --repo "${SELF_HEAL_REPO:-shin1ohno/setup}" --label "${SELF_HEAL_LABEL:-self-heal}" \
  --state open --limit 500 --json number,body,labels
```

各 issue の body から marker `self-heal-key:([0-9a-f]{40})` を抽出 → `sha1 → issue#` のマップを作る。
marker の無い issue は無視（境界 4）。`self-heal-needs-human` ラベルの有無も記録（境界 5）。

### Step 3. 差分を反映

- **NEW（ES open かつ issue 無し）** → issue 作成:

  ```bash
  body=$(cat <<EOF
  **fleet self-heal alert**（CT111 observer 検知）

  - **dedup_key**: \`$dedup_key\`
  - **source**: $source   (uptime=monitor/TLS down, es-query=Process down)
  - **severity**: $severity
  - **host/service**: ${host:-?} / ${service:-?}
  - **first_seen**: $first_seen
  - **observed**: $observed_value

  ---
  解決は self-heal-resolve loop が担当します。自動修正できない場合は \`self-heal-needs-human\` を付けて停止します。

  <!-- self-heal-key:$sha1 -->
  <!-- self-heal-source:$source -->
  EOF
  )
  gh issue create --repo "$SELF_HEAL_REPO" --label "$SELF_HEAL_LABEL" \
    --title "[self-heal] $dedup_key" --body "$body"
  ```

  作成失敗（rate limit 等）は WARN して次へ（次サイクルで再試行＝冪等）。

- **RESOLVED（open issue だが ES open 集合に無い）** → close + comment:

  ```bash
  # 境界 5: self-heal-needs-human が付いていたら close しない（comment だけ残して継続）
  gh issue close "$num" --repo "$SELF_HEAL_REPO" \
    --comment "✅ RESOLVED — observer が active を報告しなくなりました（$(date -u +%FT%TZ)）。fleet 上でクリア済み。"
  ```

  ※ self-heal-resolve が修正して close 済みのものはそもそも open issue 集合に出ないので二重 close しない。
    resolve が作業中（issue open / ES も open）のものは ES open 集合に在るので close 対象にならない。競合しない。

- **CONTINUING（両方に在る）** → 何もしない（dedup）。

### Step 4. サマリ報告

`created=N closed=M continuing=K`（＋失敗があれば列挙）を 1 行で報告。差分ゼロなら "in sync — no changes"。

## /loop での回し方

```
/loop 10m /self-heal-create
```

5 分の observer サイクルに対し 10 分間隔で十分（issue 通知の遅延上限 ~15 分）。
読み取り専用なので頻度を上げても fleet に副作用なし。
