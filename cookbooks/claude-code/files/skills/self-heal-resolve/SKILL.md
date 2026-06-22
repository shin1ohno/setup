---
name: self-heal-resolve
description: |
  self-heal observability ループの Layer 2-B（issue 解決）。shin1ohno/setup の open な
  self-heal ラベル issue を 1 件選び、fleet を調査して根本原因を特定し、修正する自律ループ。
  allowlist 内の remediation class（既知サービスの再収束／cookbook drift 修正）は
  調査→修正→PR→CI green→merge→auto-mitamae 適用→機能検証→issue close まで完全自律。
  allowlist 外（新規設計・破壊的変更・auth/secret・原因不明・3 回失敗）は PR/診断を残して
  self-heal-needs-human を付け停止。merge は CI green 必須、破壊的操作禁止、1 回 1 issue。
  「self-heal resolve」「self-heal issue を直す」「fleet alert を解決」でトリガー。
  対は self-heal-create（ES 状態を issue 化する loop）。
user-invocable: true
---

# self-heal-resolve — fleet self-heal issue の自律解決ループ

`self-heal-create` が立てた open issue を 1 件取り、根本原因を**観測で**特定し、
allowlist 内なら修正を fleet に適用して close、外なら人間にエスカレーションする。
Addy Osmani「無人ループは無人でミスするループ」への答え＝**強い安全柵 + 自動は allowlist のみ**。

設計: `docs/self-heal-github-issues-plan.md`、`~/self-heal-observability-loop-design.md`（Layer 2）。

## 不変の安全境界（常に守る）

1. **対象は `shin1ohno/setup` の open `self-heal` issue のみ**。`self-heal-needs-human` が付いた
   issue は触らない（人間待ち）。1 回の実行で **1 issue だけ**処理する（fleet 同時変更を避ける）。
2. **CI green まで merge しない**。`gh pr checks <n> --watch` が全 pass してから `gh pr merge`。
3. **破壊的操作禁止**: `rm -rf` 相当 / `terraform destroy` / DB drop / `git push --force` /
   `git push origin main`（直 push）/ snapshot 削除 / リソース削除を**自動で行わない**。
   必要なら needs-human。
4. **auth/secret/署名/IAM/KMS 関連の修正は自動で行わない** — 必ず needs-human（誤修正＝事故）。
5. **適用は「cookbook PR を main に merge → auto-mitamae が canary→fleet 適用」経由のみ**。
   ad-hoc な fleet 変更は、後述の allowlisted「transient restart」を除き行わない。
   ＝すべての永続変更が PR diff + auto-mitamae canary gate を通る。
6. **fix-loop 上限**: 同一 issue で修正試行は最大 3 回。同じ症状が 3 回残ったら設計前提を疑い
   needs-human で停止（`~/.claude/rules/debugging.md` の escalation threshold）。
7. **観測でのみ「解決」を判定**（artifact でなく機能）。「`systemctl is-active`」や「PR merged」は
   解決の証拠にならない。ES の当該 dedup_key が `resolved` に転じる／機能 probe が通ることが証拠。
8. home-monitor（CodeCommit / terraform）への変更は **PR/diff を残して needs-human**。
   このループは setup cookbook の範囲で自律する（AWS infra は人間 apply）。

## remediation class と自律可否

調査で根本原因を 1 つに特定したら class を判定する。

| class | 例 | 自律？ |
|---|---|---|
| **A. 既知サービスの再収束** | crashed systemd/docker サービスを cookbook 再適用で復旧（cookbook の notify→restart 経由）、設定 drift の再適用 | ✅ 自律（merge→auto-mitamae） |
| **B. cookbook 設定修正** | 誤った閾値 / stale な process 名で es-query rule が誤発火 → cookbook/alert rule を修正 | ✅ 自律（merge→auto-mitamae） |
| **C. transient restart** | OOM 等で一時 crash、再起動で復旧かつ flap でない既知サービス | ⚠️ 限定自律（`pct exec systemctl restart`、前後 comment + 機能 verify、flap_count を見て 2 回目以降は B/needs-human） |
| **D. 新規設計 / 破壊的 / auth / infra / 原因不明 / 複数候補** | 新コンポーネント追加、IAM、データ移行、home-monitor TF、原因が割れる | ❌ needs-human（PR/診断を残す） |

**判定に迷ったら D**（needs-human）。長期間（数週間）`active` の alert は transient ではない —
C で雑に restart せず、まず「本当に落ちているか／alert 自体が stale か」を観測で切り分ける。

## 設定（env で上書き可）

`self-heal-create` と同じ（`SELF_HEAL_REPO`/`LABEL`/`ES_HOSTS`/`ES_CA`/`ELASTIC_PW_SSM`/
`AWS_PROFILE`/`AWS_REGION`/`STATE_INDEX`）。fleet 到達は `contracts/devices.json`
（home-monitor、SSM `/host-registry/devices`）の `lxc.ip` / `ct_id` を引く。PVE LXC は
`pct exec <ct_id>` を PVE host 経由で使う（`bash -lc` でラップ — `~/.claude/rules/pve-lxc.md`）。

## 手順

### Step 0. issue 選択（無ければ STOP）

```bash
gh issue list --repo shin1ohno/setup --label self-heal --state open \
  --json number,title,body,labels,comments,createdAt
```

`self-heal-needs-human` を除外。直近で別 run が着手中（最後の comment が「🔧 着手」で 30 分以内）
の issue も除外。残りから最古を 1 件選ぶ。ゼロなら "no actionable self-heal issues — STOP"。

### Step 1. 着手マーク

`gh issue comment <n> --body "🔧 self-heal-resolve 着手（run $(date -u +%FT%TZ)）。調査開始します。"`
（重複着手を防ぐマーカー）。

### Step 2. 根本原因を観測で特定

body の `dedup_key` / `self-heal-source` を読む:
- `source=es-query`（`Process down: <host> / <proc>`）→ 対象 host で当該プロセス/サービスの実状態を見る。
  `pct exec <ct_id> -- bash -lc "systemctl status <unit>; docker compose ps; journalctl -u <unit> -n 50"`。
  **「本当に down か」「alert が stale か（プロセス名変更・metric path 変更で誤発火）」を切り分ける。**
- `source=uptime`（monitor/TLS down）→ 対象エンドポイントへ実際に到達確認（curl / tailscale ping）。

ES の現状も確認（まだ active か、resolved に転じていないか）:
```bash
# dedup_key の sha1 = self-heal-state の _id
es_get "/self-heal-state/_doc/<sha1>"   # status / first_seen / flap_count / occurrences
```
既に `resolved`（自然復旧）なら修正不要 → Step 5 で close。

### Step 3. class 判定 → 分岐

- **A/B（cookbook 経由）**:
  1. `git checkout -b fix/self-heal-<short> origin/main`（`~/.claude/rules/git-commit.md` の branch hygiene）
  2. 該当 cookbook / alert rule を修正
  3. `bin/lint-cookbooks` + `bin/audit-cookbook-reachability` + 該当の dry-run（mitamae-validator agent or
     `./bin/mitamae local <recipe>.rb --dry-run`）
  4. PR 作成（issue 番号を body に `Fixes #<n>` で紐付け）→ Step 4 へ
- **C（transient restart）**: flap_count / occurrences を確認。flap でなく既知サービスなら
  `pct exec <ct_id> -- bash -lc "systemctl restart <unit>"`（または docker compose restart）。
  issue に「restart 実行（class C, 理由 <...>）」を comment。Step 4 の検証へ（PR なし）。
  2 回目以降の同一 restart は B（恒久修正）or needs-human に格上げ。
- **D**: 修正を**適用せず** PR（あれば diagnosis 用）または diagnosis comment を残し、
  `gh issue edit <n> --add-label self-heal-needs-human` + 原因/候補/推奨対応を comment。STOP。

### Step 4. 適用（A/B のみ）

`gh pr checks <n> --watch` が全 pass → green を確認してから:
```bash
gh pr merge <pr> --repo shin1ohno/setup --squash --delete-branch
```
auto-mitamae orchestrator（CT115 cron, 5min, canary→fleet）が `origin/main` を取り込み適用する。
即時反映したい場合のみ canary host で先行 dry-run 済みなら手動 trigger 可。**canary gate が
fleet 全体への誤適用を 1 段で止める**ので、merge 後は適用完了を待って Step 5 へ。

### Step 5. 機能検証 → close（境界 7）

適用後、**機能**で検証する（artifact でなく）:
- es-query 系: 対象サービスの機能 probe（プロセス稼働 + 実機能。例 cognee なら `/health`、
  roon なら zone 応答）。
- ES の当該 dedup_key が `status:resolved` に転じるか（observer の次サイクル ≤5 分待って再確認）。

resolved を確認したら:
```bash
gh issue close <n> --repo shin1ohno/setup --comment "$(cat <<EOF
✅ RESOLVED（self-heal-resolve, class <A/B/C>）

- 根本原因: <観測に基づく原因>
- 修正: <PR #xxx / restart 等>
- 検証: <機能 probe 結果 / ES dedup_key resolved 確認>
EOF
)"
```
（self-heal-create が先に close する場合もあるが、その場合 issue は既に closed なので no-op。）

検証が通らなければ修正を再試行（Step 2 へ、最大 3 回）。3 回で resolved にならなければ
needs-human を付けて停止し、試した仮説を comment に残す（境界 6）。

### Step 6. サマリ報告

処理した issue を `resolved(class) / restarted / escalated-needs-human / no-op(already-resolved) / skipped`
で 1 行報告。

## /loop での回し方

```
/loop 30m /self-heal-resolve
```

5 分の observer + 10 分の create に対し、resolve は調査 + 適用 + 検証で時間がかかるので 30 分間隔。
**初回は対話的に 1 件（例: roon issue）で e2e を確認してから**無人 /loop に載せること（plan の方針）。
無人運用中も `self-heal-needs-human` が付いた issue はメール通知で人間に届く。
