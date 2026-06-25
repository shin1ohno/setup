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

ホスト fallback は **以下の `es_get` を verbatim で使う**（散文から再合成しないこと — `for h in $HOSTS` は
**zsh で word-split されず**、`local path=` は **zsh の $PATH 連動特殊配列を破壊**して、いずれも false
"ES unreachable → STOP" を出す）。bash/zsh 両対応:

```bash
ES_CA="${SELF_HEAL_ES_CA:-/etc/elastic-agent/certs/ca.crt}"
ES_HOSTS="${SELF_HEAL_ES_HOSTS:-https://es-0.home.local:9200 https://es-1.home.local:9200 https://es-2.home.local:9200}"

# es_get <path> <json-body>
#   rc 0 = どれかのホストが応答（hits 0 件でも rc 0＝正常な空）。stdout に body。
#   rc 1 = 全ホスト接続失敗（真の unreachable。このときだけ STOP してよい）。
# 移植性: ホスト分割は printf|tr で改行化し here-string + while-read（pipe 不使用＝関数 return が効く）。
# 変数は `epath`（`path` は zsh の $PATH 連動特殊配列）。curl は絶対パス。
es_get() {
  epath="$1"; ebody="$2"; ehost=""; eout=""
  while IFS= read -r ehost; do
    [ -n "$ehost" ] || continue
    eout=$(/usr/bin/curl -s -m 15 --cacert "$ES_CA" -u "elastic:${ES_PW}" \
             -H 'Content-Type: application/json' -X GET "${ehost}${epath}" -d "$ebody" 2>/dev/null)
    if [ -n "$eout" ] && ! printf '%s' "$eout" | grep -q '"error"[[:space:]]*:'; then
      printf '%s' "$eout"; return 0
    fi
  done <<EOF
$(printf '%s' "$ES_HOSTS" | tr ' ' '\n')
EOF
  return 1
}
```

TLS は `--cacert "$ES_CA"` で検証（`-k` 不可。通らなければ CA/到達性問題として STOP し調査）。
**空≠unreachable の鉄則**: `es_get` が **rc 0** なら、`hits.total.value=0`（open 0 件）は**正常な空＝全 resolved**で
あり STOP しない（RESOLVED 同期へ進む）。STOP は `es_get` が **rc 1（全ホスト失敗）**のときだけ。
空を unreachable と誤認して取りこぼさない／unreachable を空と誤認して mass-close しない。

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

- **NEW（ES open かつ open issue 無し）**:

  まず **直近 closed の同 marker issue を確認**（flap 再発で issue を量産しない。観測: pro/hydra flap で
  同一 sha1 の issue を 10 件量産した）。`<24h` 以内に同 `self-heal-key` で closed があれば
  **reopen + comment**（新規作成しない＝1 flap 1 issue + reopen 履歴）:

  ```bash
  reopen_num=$(gh issue list --repo "$SELF_HEAL_REPO" --label "$SELF_HEAL_LABEL" --state closed \
    --search "self-heal-key:$sha1 in:body" --limit 5 --json number,closedAt \
    | jq -r --argjson cut "$(date -u -d '24 hours ago' +%s)" \
      '[.[] | select((.closedAt|fromdateiso8601) > $cut)] | sort_by(.closedAt) | last | .number // empty')
  if [ -n "$reopen_num" ]; then
    gh issue reopen "$reopen_num" --repo "$SELF_HEAL_REPO" \
      --comment "🔁 再発（flap）: observer が再び active を報告（$(date -u +%FT%TZ)）。$observed_value"
  else
  # ↓ 直近 closed が無ければ従来どおり新規作成
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
  fi
  ```

  作成失敗（rate limit 等）は WARN して次へ（次サイクルで再試行＝冪等）。reopen/create とも
  失敗は次サイクルで再試行（冪等）。

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
