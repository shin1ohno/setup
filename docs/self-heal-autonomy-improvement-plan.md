# self-heal 自律性改善 — 実装プラン（全 Phase）

**Date**: 2026-07-05
**Issue**: shin1ohno/setup#642（設計コメント + owner 決定）
**関連**: `docs/self-heal-github-issues-plan.md`（GitHub Issues 経路への移行, 前提となる Layer 2 実装）

owner 決定（#642）:

1. 4 軸すべてを対象（基盤の堅牢化 / 診断精度 / remediation allowlist 拡張 / infra 経路）。
2. Phase 3 = **案 B**（可逆な CT `memory`/`cores` resize のみ完全自動、それ以外は needs-human）。
3. 追加原則: **曖昧な二択は両候補を PR まで作って人間が選ぶ**（cross-cutting）。
4. 各 Phase に **black/white の完了条件**（Claude が実行して一意に pass/fail 判定できる形）を付す。

## 完了条件の書式（全 Phase 共通）

各 Phase の「完了条件（DONE gate）」は次の性質を満たす。Claude はこの gate を順に実行し、**全項目 pass で初めてその Phase を「完了」と報告する**。

- 各項目は 1 本のコマンド or grep で **exit code / 件数 / 文字列一致** に還元でき、主観判断を含まない。
- 「コードが compile した」「dry-run が通った」は必要条件だが、fleet 適用を要する項目は **merge + auto-mitamae 適用後の観測**（metric 存在・機能 probe）まで含める。
- 1 つでも fail なら Phase 未完。fix→再実行、3 回で設計前提を疑う（`~/.claude/rules/debugging.md`）。

---

## 0. 前提と不変の安全境界

self-heal-resolve の既存 8 境界（`cookbooks/claude-code/files/skills/self-heal-resolve/SKILL.md` §不変の安全境界）と class A–D は本改善で**緩めない**。範囲を広げる Phase 2/3 は「散文の許可」ではなく **checked-in の allowlist データ + それを強制する helper（コード）** で境界を表現する。境界緩和はすべて PR review を通るデータ変更に還元する。

Phase 0/1 は境界内で自律の**質**を上げる（新境界を作らない）。Phase 2/3 は allowlist データで自律の**範囲**を広げる（helper がテーブル外を拒否）。

## 1. Phase 0 — ループ基盤の堅牢化（"直す前に死なない"）

### 問題

- create/resolve ループは `~/.claude/logs/*.last` を書くだけ。observer は node-exporter textfile metric（`self_heal_observer_last_run_timestamp_seconds`）を出し `SelfHealObserverStale` で監視されるが、**ループ自身の停止は誰も検知しない**。
- `~/.claude/.credentials.json` の OAuth 失効でヘッドレス `claude -p` が rc≠0 を無言で吐き続ける（`TODO.md` "self-heal-loops headless auth" 記載）。

### 変更

1. **ループ liveness metric**（新ファイル `cookbooks/self-heal-loops/files/self-heal-metric.sh`, 両 wrapper が source）
   - 各ループが**サイクル末尾で必ず**（gate-skip / auth-fail 含む）以下を atomic に書く:
     - create → `/var/lib/node_exporter/textfile/self-heal-create.prom`
     - resolve → `/var/lib/node_exporter/textfile/self-heal-resolve.prom`
     - メトリクス: `self_heal_loop_last_run_timestamp_seconds{loop="…"}` + `self_heal_loop_status{loop="…",result="ok|error|auth"}`。
   - **ループ毎に別ファイル**にして 2 cron の write レースを避ける（node-exporter textfile collector はディレクトリ内 `*.prom` を merge）。
   - `self-heal-create-run.sh` / `self-heal-resolve-run.sh` を改修し全 exit path（DISABLED skip / gate skip=0 / claude rc / auth-fail）で metric を書く。
2. **loop-user 所有の `.prom` を事前作成**（`cookbooks/self-heal-loops/default.rb`, 実装時に確定した最終形）
   - ループは `runuser -l shin1ohno` で走る非 root。node-exporter が実際に scrape する `/var/lib/node_exporter/textfile`（pro-dev では `root:root 0755`）に書く必要がある。
   - **採用（dir 権限は無変更）**: cookbook が `self-heal-create.prom` / `self-heal-resolve.prom` を **loop-user 所有（0644）で事前作成**（`install /dev/null`, first-apply のみ・not_if で owner 一致を確認）。wrapper は**ファイルを所有**するので dir 書込不要、単一 `printf` redirection で in-place 更新する。node-exporter が後段（lxc_entry）で dir を再確保しても衝突しない。
   - 却下案: (a) textfile dir を group 所有 + `g+w,g+s` に変更 — node-exporter が self-heal-loops の後に走り dir を root:root へ戻すため ordering 衝突、かつ共有 dir の perms 緩和になる。(b) root 所有 staging + sudo move — ヘッドレス cron で sudo 依存は脆い。
   - 非 atomic 性（tmp+rename 不可）は許容: payload 8 行・単一 write で実質 atomic、node-exporter は稀な partial read を次 scrape で self-correct。
3. **OAuth 失効を silent fail にしない**
   - 根本策: interactive `.credentials.json`（失効する）→ `claude setup-token` の長寿命 `CLAUDE_CODE_OAUTH_TOKEN`（`~/.claude/rules/claude-cli-headless.md`）。token は mode-600 の `~/.claude/self-heal-token.env` に置き、両 wrapper が source。auth presence gate は `test -s <token-file>`（`claude auth status` は setup-token では `loggedIn:false` を返すため使わない）。
   - `claude setup-token` は対話が要る → owner が 1 回実行する `!` ステップとしてプランに明記（後述 §7）。
   - 繋ぎ: wrapper に auth pre-check（token file 不在/空 → `result="auth"` metric + skip、claude を起動しない）。
4. **アラート**（`cookbooks/lxc-monitoring/files/alerts/self-heal.yml`, observer の既存パターン踏襲）
   - `SelfHealLoopStale`: `time() - self_heal_loop_last_run_timestamp_seconds{loop="create"} > 900`（15m）/ `{loop="resolve"} > 2400`（40m）＝cron 間隔 2–5m の 3–8 倍。
   - `SelfHealLoopAuthExpired`: `self_heal_loop_status{result="auth"} == 1`。
   - `SelfHealLoopErroring`: `self_heal_loop_status{result="error"} == 1`（claude rc≠0 が継続）。

### 完了条件（black/white — DONE gate）

1. `bash -n` が `self-heal-metric.sh` / `self-heal-create-run.sh` / `self-heal-resolve-run.sh` で exit 0、`shellcheck -S error` が 3 本すべて exit 0。
2. `bin/lint-cookbooks` と `bin/audit-cookbook-reachability` が exit 0。
3. `./bin/mitamae local pve/lxc-pro-dev.rb --dry-run` が exit 0（self-heal-loops リソースがエラーなく plan される）。
4. PR CI（syntax-check / test-linux / test-macos / ssm-validation / error-simulation）すべて `pass`。
5. **merge + auto-mitamae 適用後**、pro-dev で `curl -s localhost:9100/metrics | grep -c '^self_heal_loop_last_run_timestamp_seconds'` == **2**、`grep -c '^self_heal_loop_status'` ≥ **2**。
6. `promtool test rules <fixture>` が exit 0（`SelfHealLoopStale`/`AuthExpired`/`Erroring` の pass/fail 両ケースを含む）。
7. auth pre-check: `~/.claude/self-heal-token.env` を退避 → create wrapper を手動 1 回実行 → ログに `result=auth` 記録かつ **claude 未起動**（`=== create cycle start ... claude` 行が増えない）。token を戻すと通常サイクルに戻る。

### PR

- **PR-0a**: metric helper + wrapper 改修 + textfile perms（setup）。
- **PR-0b**: `self-heal.yml` 3 alert（setup, lxc-monitoring, CT115 適用）。
- setup-token 移行は cookbook 変更 + owner `!` 実行（§7）。PR-0a に env-file 読取ロジックを含める。

## 2. Phase 1 — 診断精度（誤診で needs-human 化しない）

### 問題

#603/#567: ループは「etserver wedge + watchdog 未ロード」と診断→needs-human したが真因は mini の auto-sleep。sandbox の `netstat`/`lsof` 空返しが誤診を助長。観測 caveat は #603 後に SKILL の**散文**へ追記済みだが、散文はループが飛ばせる。

### 変更

1. **観測 caveat を実行可能 probe helper に昇格**（新ファイル `cookbooks/self-heal-loops/files/self-heal-probe.sh`, /usr/local/bin へ配備）
   - `classify_port <host> <port>`: `nc -z` の結果を `refused`（wedge 候補）/ `timeout`（sleep・fw・経路）/ `open` に分類。**既知の閉ポートが refused になること**で probe 自体の妥当性を先に確認（sandbox 盲目化検出）。
   - `check_sleep <host>`（darwin）: `pmset -g log` の Sleep/DarkWake 遷移がアラート時刻に重なるか。
   - sleep-vs-wedge 決定表を helper に埋め込む（#603 由来のケース）。
2. **エスカレーション前の confidence gate**（`self-heal-resolve/SKILL.md` Step 2 改修）
   - class-D needs-human 診断を書く前に **positive な観測エビデンス**を要求。唯一の根拠が sandbox-blind な空結果なら low-confidence とみなし (a) `pct exec`/ssh で実 connect し直す、(b) 無理なら「needs-human: 観測不能（原因未確定）」として**誤った root cause を書かない**。
   - Step 2 は散文の遵守任せをやめ `self-heal-probe.sh` の呼出を必須手順にする。

### 完了条件（black/white — DONE gate）

1. `bash -n self-heal-probe.sh` exit 0、`shellcheck -S error` exit 0。
2. `self-heal-probe.sh classify_port 127.0.0.1 22` → stdout `open`。既知の閉ポート `self-heal-probe.sh classify_port 127.0.0.1 9` → `refused`。SYN drop するポート → `timeout`。3 分類すべて期待値一致（exit 0）。
3. `self-heal-probe.sh --self-test` が exit 0。内部に #603 fixture（target port timeout かつ ssh:22 open, darwin）を含み `sleep-suspect` を返すこと、空 `netstat` 入力で「listener 無し」断定を返さないことを assert。
4. `grep -c 'self-heal-probe.sh' cookbooks/claude-code/files/skills/self-heal-resolve/SKILL.md` ≥ 1（Step 2 が probe helper 呼出を必須化）。
5. SKILL に confidence gate 文言が存在（`grep -Ec '空.*netstat|観測不能|positive.*エビデンス' SKILL.md` ≥ 1）。
6. `bin/lint-cookbooks` exit 0、`./bin/mitamae local pve/lxc-pro-dev.rb --dry-run` exit 0、PR CI 全 `pass`。

### PR

- **PR-1**: probe helper + SKILL Step 2 改修（setup）。

## 3. Phase 2 — remediation allowlist 拡張（class C/darwin をゲート付き自動化）

### 問題

darwin remediation（`launchctl kickstart`、et wedge 回復）は全て class D→needs-human。既知・冪等・非破壊の回復手順すら PR 化も自動実行もできない。

### 変更

1. **known-safe kick を allowlist データ化**（新ファイル `cookbooks/self-heal-loops/files/remediation-allowlist.json`）
   - スキーマ: `[{host, service, recovery_command, flap_window_min, max_kicks_per_window}]`。
   - 例: `{mini, homebrew.mxcl.et, "launchctl kickstart -k system/homebrew.mxcl.et", 60, 1}`、`{<linux-host>, <unit>, "systemctl restart <unit>", 60, 1}`。
2. **allowlist を強制する helper**（新ファイル `cookbooks/self-heal-loops/files/self-heal-remediate.sh`）
   - 入力 `(host, service)` がテーブルに**厳密一致**した時だけ、そのエントリの `recovery_command` を実行。**任意コマンドは実行不可**（フェンスをコードで強制）。
   - 前後に機能 probe（`self-heal-probe.sh` 再利用）。`flap_window` 内で `max_kicks` 超過なら **B（恒久修正）/ needs-human へ格上げ**し kick しない。
3. **SKILL に class C' を追加**（`self-heal-resolve/SKILL.md`）
   - class 表に C'（known-safe kick, allowlist 一致時のみ PR 無し自律）を追加。テーブル外は class D のまま。破壊的/auth/secret は allowlist に載せない。
   - allowlist は PR review で増やすデータ（`bin/lint-cookbooks` に JSON schema チェックを足すか検討）。

### 完了条件（black/white — DONE gate）

1. `jq empty cookbooks/self-heal-loops/files/remediation-allowlist.json` exit 0（valid JSON）。schema 検証（必須キー host/service/recovery_command/flap_window_min/max_kicks_per_window の存在）を `jq` one-liner で assert し exit 0。
2. `self-heal-remediate.sh --dry-run <in-table-host> <in-table-service>` → exit 0、stdout がテーブルの `recovery_command` と完全一致。
3. `self-heal-remediate.sh --dry-run bogus-host bogus-svc` → exit≠0（テーブル外拒否＝任意コマンド実行不可をコードで強制）。
4. flap-guard: `max_kicks` 超過を模した状態で `self-heal-remediate.sh <in-table>` → stdout `escalate`、recovery_command を実行しない（distinct exit code）。
5. `grep -c "class C'" cookbooks/claude-code/files/skills/self-heal-resolve/SKILL.md` ≥ 1。
6. `bin/lint-cookbooks` exit 0、dry-run exit 0、PR CI 全 `pass`。
7. **e2e（機能）**: allowlist の 1 サービスを pro-dev で意図的に停止 → helper kick → `self-heal-probe.sh classify_port` が `open` に復帰。初回は対話 run で確認してから無人化。

### PR

- **PR-2**: allowlist JSON + remediate helper + SKILL class C'（setup）。

## 4. Phase 3 — infra/home-monitor 経路（案 B、境界を跨ぐ・最高リスク）

> **⚠️ この §4 は `docs/self-heal-phase3-security-review.md` で上書きされた**（2026-07-05）。adversarial review が
> 案B-as-specced に **blockers: 3**（floor 無し縮小 OOM / admin-gate は境界でない / PVE token 未スコープ）を検出。
> owner 決定 = **hardening 込みで案B 実装**。実際の設計・実装内訳・DONE gate・owner provision 前提は
> security-review doc を参照。以下の初版 §4 は歴史的経緯として残す。

### 問題

境界 #8 が home-monitor TF を人間 apply 固定。#557（RAM resize）は owner GO 後もループに TF 変更を用意する手段すら無く放置。

### 前提（確認済み）

- `home-monitor/pve-lxcs.tf`: `local.lxc_specs` マップが `cores` と `memory.dedicated` を持つ。resize = マップ 1 エントリの編集。
- pro-dev: `terraform`（/usr/bin）、AWS profile `sh1admn`、CodeCommit remote `codecommit::ap-northeast-1://sh1admn@home-monitor` 到達可。

### ⚠️ セキュリティ前提（実装前に必須）

**自律ループが `sh1admn`（admin プロファイル）+ PVE provider token で `terraform apply` する = 権限拡大**。`CLAUDE.md` の「network-exposed LXC に admin(sh1admn) キーを渡さない」原則の境界事案（pro-dev は dev-workstation で既に sh1admn を持つが、**ヘッドレス bypassPermissions ループ**が admin-scope の apply を叩けるようにするのが新しい露出）。実装前に必須:

1. **adversarial review**（`~/.claude/rules/adversarial-review.md`, privilege boundaries / secret mounts）を sub-agent で実行。
2. **capability probe**: pro-dev の loop identity（shin1ohno）から `terraform plan`（home-monitor）が通るか、PVE provider の API token をどこから読むか（`~/.claude/rules/aws-iam.md` "Probe preconditions on the real host"）。
3. apply 対象 profile を **最小権限**にできないか検討（sh1admn 全権ではなく resize に必要な PVE API scope + CodeCommit + TF backend のみのサブ profile）。

### 変更（レビュー通過後）

1. **可逆 resize allowlist**（新ファイル `cookbooks/self-heal-loops/files/infra-resize-allowlist.json`）
   - per-CT の `{ct, allow_fields:["memory","cores"], max_memory_mb, max_cores}` 上限。ループが CT を無制限に増やせないようキャップ。`rootfs` は**含めない**（ZFS refquota 非可逆性 — `pct set -rootfs` は refquota に伝播しない, `~/.claude/rules/pve-lxc.md`。案 A 相当=PR+plan→owner apply に留める）。
2. **plan-gated apply**（`self-heal-resolve/SKILL.md` Phase 3 case + helper `self-heal-infra-apply.sh`）
   - branch → `lxc_specs` の対象 CT の memory/cores を allowlist キャップ内で編集。
   - `terraform plan -out=tfplan` → `terraform show -json tfplan` を parse し **(a) `resource_changes` の action が対象 CT の `["update"]` のみ, (b) `0 to destroy`, (c) 対象 CT 以外の変化ゼロ, (d) 変更フィールドが memory/cores のみ** を assert。1 つでも外れたら **即 needs-human**（apply しない）。
   - assert 通過時のみ `terraform apply tfplan`。apply は `origin/main` から（`~/.claude/rules/aws-iam.md` Terraform Apply Branch Gate）＝ home-monitor PR を merge→pull→apply の順。
   - IAM/SG/リソース作成削除は対象外（完全人間）。
3. **境界更新**（SKILL §不変の安全境界 #8）
   - 「home-monitor TF は常に needs-human」→「案 B: infra-resize-allowlist 内の可逆 resize は plan-gate 通過時のみ自律 apply、それ以外の home-monitor TF は needs-human」。

### 完了条件（black/white — DONE gate）

1. **PR-3a（前提ゲート）**: adversarial review レポートが committed、末尾に `blockers: 0`（全 blocker 解消 or 該当なし）。capability probe 結果（`terraform plan` 到達可否・PVE provider token 供給元・採用 profile）が doc に記録。**この項目が pass するまで PR-3b の実装コードを書かない。**
2. `jq empty infra-resize-allowlist.json` exit 0、各エントリに `ct`/`allow_fields`/`max_memory_mb`/`max_cores`、`grep -c 'rootfs' infra-resize-allowlist.json` == **0**（rootfs 非対象）。
3. plan-gate helper のフィクスチャテスト（`self-heal-infra-apply.sh --self-test` or CI, exit 0）:
   - fixture A（対象 CT の memory のみ in-place update, 0 destroy）→ `approve`, exit 0。
   - fixture B（`delete`/`replace`/対象外リソース変化を含む）→ `abort→needs-human`, exit≠0。
   - fixture C（allowlist キャップ超過）→ `refuse`, exit≠0。
4. `grep -c '案 B' cookbooks/claude-code/files/skills/self-heal-resolve/SKILL.md` ≥ 1（§不変の安全境界 #8 更新）。
5. `bin/lint-cookbooks` exit 0、dry-run exit 0、PR CI 全 `pass`。
6. **e2e（機能, 対話 run で 1 回）**: #557 相当の可逆 resize を実行 → 対象 CT の実 memory が反映（`pct config <ct> | grep memory`）→ 対象サービス機能復帰。plan に destroy が出れば abort→needs-human することを別途 dry で確認。

### PR

- **PR-3a**: adversarial review レポート + capability probe 結果（doc, setup）。
- **PR-3b**: infra-resize-allowlist + plan-gate helper + SKILL Phase 3（setup）。
- home-monitor 側は必要なら TF の loop-apply 用 backend/権限整備（別 PR, CodeCommit, user-gated）。

## 5. Cross-cutting — 曖昧な二択は両候補を PR まで作って人間が選ぶ

`self-heal-resolve/SKILL.md` の class D / 「判定に迷ったら D」を **multi-candidate propose モード**で置換。

- **発火条件**: **2 件（最大 3）の viable かつ envelope 内**（非破壊・auth/secret/IAM/KMS 非該当・setup cookbook か Phase3-B の可逆 infra allowlist の範囲）な候補 remediation を特定し、**確信を持って優劣を付けられない**とき。「何が壊れているか分からない」場合は従来どおり診断のみ needs-human（候補を捏造しない）。
- **動作**: 各候補を独立 branch→PR 化（PR body に実装計画＝変更内容・理由・sibling との trade-off）。PR 同士 + issue を相互リンク。issue と**両 PR に `self-heal-needs-human`**。issue に 1 コメント「候補 A(#PRx)/B(#PRy) — trade-off 表。採用する方を選んでください（他方は close）`<!-- self-heal-bot -->`」。**2 PR は同一 run で作る**（以後 Step 0 dup-guard が「open linked PR≥1 + needs-human」で skip）。
- **人間の解決**: owner が採用側にコメント（既存 user-signal 経路 / Phase 2-C）→ GO 承認。採用 PR は CI green かつ envelope 内なら merge→検証→close（Phase3-B infra なら案 B 規則）。非採用 PR は close。
- **不変ガード**: どちらの候補も**人間が選ぶまで auto-merge しない**（両方 class-D/needs-human）。**Step 0 dup-guard を「複数 open linked PR + needs-human → skip（片方を勝手に merge しない）」に対応**させる。envelope を跨ぐ候補は PR 化せず診断内で言及のみ。両 PR 作成は当該 run の 1-issue 予算を消費、3-try escalation は据え置き。

### 完了条件（black/white — DONE gate）

1. `grep -c 'multi-candidate' cookbooks/claude-code/files/skills/self-heal-resolve/SKILL.md` ≥ 1（モード節が存在）。
2. Step 0 dup-guard が「複数 open linked PR + needs-human → skip」を明記（`grep -Ec '複数.*linked PR|片方を.*merge しない' SKILL.md` ≥ 1）。
3. ガード 3 文言がすべて grep で存在: 「両 PR に…needs-human」「人間が選ぶまで…auto-merge しない」「envelope 外…materialize しない」。
4. resolve-run.sh の pre-flight gate が複数 linked-PR issue で誤 merge を誘発しない: 当該 needs-human issue が gate の actionable カウントに入らないことを `SELF_HEAL_GATE_ONLY=1 self-heal-resolve-run.sh` + 複数 linked-PR fixture で確認（gate ログ `actionable=0`）。
5. **e2e（対話 run で 1 回）**: 二択が成立するテスト issue で両候補 PR が作られ両方に needs-human が付き、どちらも auto-merge されないこと、owner コメントで片方が採用されもう片方が close されることを確認。
6. `bin/lint-cookbooks` exit 0、PR CI 全 `pass`。

### PR

- **PR-X**: SKILL の multi-candidate propose モード + Step 0 dup-guard の複数 linked-PR 対応（setup）。Phase 2 完了後（class C' と整合させる）に実装。

## 6. 実装順・依存・リポ分割

```
PR-0a/0b (基盤)  →  PR-1 (診断)  →  PR-2 (allowlist) + PR-X (multi-candidate)  →  PR-3a (review) → PR-3b (infra 案B)
```

- **setup repo**: Phase 0/1/2 + cross-cutting + Phase 3 のループ側ロジック（all cookbook/SKILL）。各 Phase 独立 PR、mitamae dry-run + `bin/lint-cookbooks` + `bin/audit-cookbook-reachability` を CI gate に。
- **home-monitor repo**（CodeCommit, user-gated）: Phase 3 の TF backend/権限整備が必要な場合のみ。
- 0/1/2 は既存境界を緩めない → 先行して安全に merge・fleet 適用（auto-mitamae canary→pro-dev）。
- 3 は security 前提（§4 の adversarial review + capability probe）通過後にのみ実装着手。
- 各 Phase は自身の「完了条件（DONE gate）」を全 pass してから次 Phase に進む。

## 7. Owner 手動ステップ（`!` 実行）

- Phase 0: `claude setup-token` を pro-dev の shin1ohno で 1 回実行し、出力 token を `~/.claude/self-heal-token.env`（`CLAUDE_CODE_OAUTH_TOKEN=…`, mode 600）に保存。cookbook はこのファイルを配置しない（秘密なので owner が置く）。
- Phase 3: adversarial review 結果を見て案 B の apply 権限付与を承認 or サブ profile を作成。

## 8. 未決事項

- ~~Phase 3 の apply 用に sh1admn 全権を使うか、resize 専用の最小権限サブ profile を切るか~~ → **決定済み**:
  専用 non-admin `pve-resize` sub-profile + スコープ化 PVE token/role（`docs/self-heal-phase3-security-review.md` §B）。
  adversarial review が sh1admn 直用を blocker 2a として却下。
- `bin/lint-cookbooks` に allowlist JSON schema チェックを足すか（Phase 2）。
