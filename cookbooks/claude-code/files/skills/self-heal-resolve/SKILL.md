---
name: self-heal-resolve
description: |
  self-heal observability ループの Layer 2-B（issue 解決）。shin1ohno/setup の open な
  self-heal ラベル issue を 1 件選び、fleet を調査して根本原因を特定し、修正する自律ループ。
  allowlist 内の remediation class（既知サービスの再収束／cookbook drift 修正）は
  調査→修正→PR→CI green→merge→auto-mitamae 適用→機能検証→issue close まで完全自律。
  allowlist 外（新規設計・破壊的変更・auth/secret・原因不明・3 回失敗）は PR/診断を残して
  self-heal-needs-human を付け停止。merge は CI green 必須、破壊的操作禁止、1 回 1 issue。
  owner(shin1ohno) が issue/PR に付けたコメント・更新は GO 承認として拾い、needs-human でも
  再着手する（第三者のコメント・更新は無視。bot コメントは <!-- self-heal-bot --> で識別）。
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
   issue は原則触らない（人間待ち）。**唯一の例外**: owner（`shin1ohno`）の未処理ユーザー信号を持つ
   issue は needs-human でも再着手し、その信号を GO 承認として扱う（後述
   「ユーザー信号と identity 判定」）。ユーザー信号は needs-human の**評価ゲートのみ**を解除し、
   境界 2–8 のハード境界は一切 waive しない。1 回の実行で **1 issue だけ**処理する（fleet 同時変更を避ける）。
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
`AWS_PROFILE`/`AWS_REGION`/`STATE_INDEX`）。加えて `SELF_HEAL_OWNER`（既定 `shin1ohno`、
repo owner）＝「ユーザー信号」の著者として認める唯一の login。fleet 到達は `contracts/devices.json`
（home-monitor、SSM `/host-registry/devices`）の `lxc.ip` / `ct_id` を引く。PVE LXC は
`pct exec <ct_id>` を PVE host 経由で使う（`bash -lc` でラップ — `~/.claude/rules/pve-lxc.md`）。

## ユーザー信号と identity 判定（第三者は無視）

このループは `gh` を **owner 本人（`shin1ohno`）のトークン**で叩くため、ループ自身が投稿する
コメントの著者 login も `shin1ohno` になる。「著者が誰か」だけでは *ユーザーの指示* と
*ループ自身のコメント* を区別できない。そこで **bot コメントには必ずマーカー
`<!-- self-heal-bot -->` を付け**、3 分類で判定する:

| 分類 | 判定 | 扱い |
|---|---|---|
| **第三者** | コメント/レビュー著者の login != `SELF_HEAL_OWNER` | **完全無視**（信号にしない・反応しない） |
| **ループ自身** | 著者 == owner **かつ** bot 判定 true | 信号にしない（watermark に使う） |
| **ユーザー信号** | 著者 == owner **かつ** bot 判定 **false** | 再着手の引き金（GO 承認） |

**bot 判定（is-loop-comment）** = body が次のいずれかに合致:
1. `<!-- self-heal-bot -->` マーカーを含む（新規コメントの正規手段）
2. `self-heal-resolve` または `self-heal-create` の文字列を含む（resolve の着手/診断コメント）
3. 先頭が `🔁 再発` または `✅ RESOLVED`（マーカー導入**前**に create.sh が投稿した旧コメントの救済）

2・3 はマーカー導入前から open のままの issue（例: 移行直前に旧 resolve が `🔧 着手 self-heal-resolve …`
や `🔬 self-heal-resolve 診断` を付けた #587/#588）を、誤ってユーザー信号と認識しないための保険。
新コメントはすべて 1 のマーカーを持つので、旧コメントが close で消えれば 2・3 は不要になる。

**bot マーカー必須（不変規約）**: このループが `gh issue comment` / `gh issue close --comment` /
`gh issue reopen --comment` / `gh pr comment` で投稿する **すべてのコメント** の body 末尾に
`<!-- self-heal-bot -->` を付ける。これを忘れると自分のコメントを次サイクルでユーザー信号と
誤認して無限ループする。

**未処理ユーザー信号の検出（ステートレス watermark）**: 対象 issue（および linked PR）上で、
- 最新の *ユーザー信号コメント*（owner 著・マーカー無し）の `createdAt`
  **>** 最新の *bot マーカーコメント* の `createdAt`

なら未処理のユーザー信号あり。再着手時に bot マーカー付き ack コメントを投稿すると、それが新しい
watermark になり、次サイクルはユーザーが再度コメントするまで再発火しない（追加ストレージ不要）。
issue の本文編集は `lastEditedAt` > 最新 bot コメント `createdAt` を best-effort 信号として扱う。
ラベルからの `self-heal-needs-human` 除去は、それだけで通常の actionable issue として拾われる
（既存挙動）。

判定の最小ワンライナー例:
```bash
OWNER="${SELF_HEAL_OWNER:-shin1ohno}"
# pipe to real jq so --arg works (gh の組み込み --jq は --arg 非対応)
# is_bot = marker OR resolve/create を含む OR 旧 create プレフィックス（移行期救済）
gh issue view <n> --repo shin1ohno/setup --json comments | jq --arg o "$OWNER" '
  def is_bot: .body | (test("<!-- self-heal-bot -->") or test("self-heal-(resolve|create)") or test("^(🔁 再発|✅ RESOLVED)"));
  (.comments | map(select(.author.login==$o and (is_bot|not))) | last | .createdAt) as $u
  | (.comments | map(select(is_bot)) | last | .createdAt) as $b
  | {user_signal:$u, last_bot:$b, actionable: ($u != null and ($b == null or $u > $b))}'
```
linked PR のレビュー/コメントも同型（`gh pr view <pr> --json comments,reviews` の owner 著・
マーカー無しエントリを見る）。

## 手順

### Step 0. issue 選択 + 部分状態回復（無ければ STOP）

```bash
gh issue list --repo shin1ohno/setup --label self-heal --state open \
  --json number,title,body,labels,comments,createdAt
```

まず各 open issue（**needs-human 付きも含めて取得**）について「ユーザー信号と identity 判定」の
watermark で **user-unblocked か** を判定する（owner 著・マーカー無しの最新コメント >
最新 bot コメント、または linked PR の owner レビュー/コメント、または本文編集）。

**選択優先度**: user-unblocked issue を**最優先**で 1 件選ぶ（ユーザーが能動的に待っている）。
無ければ従来どおり needs-human 無しの actionable から最古を選ぶ。第三者（owner 以外）の
コメント・更新は信号として数えない。

除外/分岐ルール（無人 cron 耐性。`docs/self-heal-github-issues-plan.md` の
dup ガード + partial-state recovery）:

1. **`self-heal-needs-human` 付きは除外** — **ただし user-unblocked なら例外的に着手対象**
   （後述「user-unblocked の処理」）。それ以外の needs-human は人間待ちで除外。
2. **open な linked PR を持つ issue は新規 PR を作らない**（重複 PR 防止）。代わりに
   その PR の状態で分岐 — `gh pr list --repo shin1ohno/setup --search "<issue># in:body linked:issue" --state open`
   や issue の timeline で `Fixes #<n>` の PR を特定し:
   - **owner の未処理レビュー/コメントがあるか先に確認**（owner 著・マーカー無し・最新 bot 活動より新しい）。
     あれば最優先で反映する: 指摘を読み、**PR ブランチに修正を push**（新規 PR は作らない）、CI を再実行、
     bot マーカー付きで「反映しました」コメント。**merge は CI green ＋未解決の owner レビュー無し ＋
     （class A/B または user-GO 済み）** が揃ってから（Step 4）。auth/secret/破壊的指摘なら needs-human。
   - **まず class を再判定**。linked PR が **class D（propose-only / major・破壊的変更 / body に class-D 指示）**で
     **user-GO が無い**なら **絶対に auto-merge しない** → `self-heal-needs-human` を付与して STOP（dup-guard の
     merge は class A/B の自動修正 PR、または user-GO 済みに限る。CI green は merge 許可の十分条件ではない）。
   - class A/B（または user-GO 済み）かつ CI green → **Step 4（merge + 検証）へ直行**（再調査しない）
   - CI red / conflict → diagnose して `self-heal-needs-human`
   - CI 進行中 → 今回はスキップ（次サイクルで再評価）
3. **「🔧 着手」comment があるが open PR 無し**: 30 分以内なら別 run 進行中としてスキップ。
   30 分超なら**前回 run が途中で死んだ**と判断し、その issue を優先再開（孤児 branch が
   あれば確認して再利用 or 破棄。partial-state を放置しない）。
4. 上記で残った actionable issue から最古を 1 件選ぶ。ゼロなら
   "no actionable self-heal issues — STOP"。

### Step 0.5. user-unblocked の処理（user-unblocked を選んだ場合のみ）

owner の未処理ユーザー信号で選ばれた issue は、その信号を **GO 承認**として扱う:

1. **ack コメント投稿**（bot マーカー必須）。ユーザー指示を 1–2 行で要約し着手宣言:
   `gh issue comment <n> --body "🔧 ユーザー指示を受領（run $(date -u +%FT%TZ)）: <要約>。着手します。<!-- self-heal-bot -->"`
   このコメントが watermark を更新し、次サイクルの重複着手を防ぐ。
2. needs-human が付いていれば**外す**（自律トラックに戻す）:
   `gh issue edit <n> --repo shin1ohno/setup --remove-label self-heal-needs-human`
3. ユーザーコメント本文を**追加の文脈・指示**として Step 2 以降を実行する。**class D でも GO 済みなら
   実装まで進む**（新規 cookbook 追加等）。
4. **ハード境界は不変**（境界 2–8）。CI green まで merge しない／破壊的操作・auth/secret/IAM/KMS の
   自動修正禁止／適用は PR→auto-mitamae 経由のみ／home-monitor TF は needs-human／3 回失敗で停止。
   これらに抵触したら `self-heal-needs-human` を**再付与**して停止（理由を bot マーカー付き comment で残す）。
   **ユーザーのコメントはハード境界を waive しない** — needs-human の評価ゲートだけを解除した。

ユーザー信号が「停止して」「やめて」等の中止指示なら、着手せず needs-human を維持（または付与）して
その旨を bot マーカー付き comment で残し STOP。

### Step 1. 着手マーク

`gh issue comment <n> --body "🔧 self-heal-resolve 着手（run $(date -u +%FT%TZ)）。調査開始します。<!-- self-heal-bot -->"`
（重複着手を防ぐマーカー。**末尾の `<!-- self-heal-bot -->` は必須** — 無いと自分のコメントを
ユーザー信号と誤認する）。Step 0.5 で ack 済みなら本 Step は省略可。

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
  issue に「restart 実行（class C, 理由 <...>）<!-- self-heal-bot -->」を comment。Step 4 の検証へ（PR なし）。
  2 回目以降の同一 restart は B（恒久修正）or needs-human に格上げ。
- **D**: 修正を auto-apply せず、調査結果を残して人間に渡す。**実装 PR を作ってもよい（propose）**が、
  作ったら**同じ run で即座に** `gh issue edit <n> --add-label self-heal-needs-human` を付与する
  （CI 完了を待たない）。理由: needs-human を付けないと、次 run の Step 0 dup-guard が「open linked PR +
  CI green → merge」で **class-D PR を無人 auto-merge してしまう**。needs-human → Step 0 で除外 → 再評価
  されず、人間の review/merge を待てる。PR を作らない場合も diagnosis comment + `self-heal-needs-human`
  を付けて STOP。いずれも原因/候補/推奨対応を comment。

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
<!-- self-heal-bot -->
EOF
)"
```
（self-heal-create が先に close する場合もあるが、その場合 issue は既に closed なので no-op。
close/diagnosis を含むループの**全コメント末尾に `<!-- self-heal-bot -->` を必須**。）

検証が通らなければ修正を再試行（Step 2 へ、最大 3 回）。3 回で resolved にならなければ
needs-human を付けて停止し、試した仮説を comment（マーカー付き）に残す（境界 6）。

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
