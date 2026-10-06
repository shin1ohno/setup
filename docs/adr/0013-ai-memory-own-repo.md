# ADR 0013: ai-memory（memory-v2）を独立リポ `shin1ohno/ai-memory` へ移し、setup は取得・配置・設定を持つ

**Status**: Accepted（2026-09-28、ユーザー決定）

## Context

memory-v2（以下 ai-memory）は、claude.ai の memory connector と Claude Code のファイル記憶ミラーが読み書きする
個人の記憶ストアで、CT 119（es-memory、192.168.1.83）上の 3 つの runtime ユニットから成る（survey
`runtime-code.summary` 1）。

- memory-mcp: 6 モジュール。`mcp<2`・starlette・httpx で動き、`127.0.0.1:8010` で待つ
- memory-keeper: 6 モジュール + prompts 2 本。stdlib だけを使い、reconcile と consolidate の timer が
  `/usr/bin/python3` で起動する（health の timer は `memory-keeper-health.sh` を起動する）
- auth-proxy: `proxy.py` 1 本。aiohttp・PyJWT・OTel を使い、`0.0.0.0:8767` で待つ（`memory-v2-proxy.service:17`、
  `proxy.py:399`）。memory-mcp と auth-proxy は 1 つの venv を共有し、`requirements.txt` と `requirements-v2.txt` を
  重ねて入れる（`lxc-es-memory/default.rb:11,61-92`）
- 付随物: ES 索引 JSON 4 本 + `setup_indices_v2.sh`、systemd unit 8 本、`generate_env_v2.sh`、
  `memory-keeper-health.sh`、`eval/`、`migrate/`

実装はすべて setup にある。`cookbooks/lxc-es-memory` の追跡ファイルは 47 本（うち `files/` 45 本、8d3b48b で
`git ls-files`）で、`default.rb`（463 行）が `/opt/es-memory/app-v2` と `/opt/es-memory/keeper` へ置く。env は
`pve-bootstrap-ssm` プロファイルで SSM の `/monitoring/elastic/elastic-password` と `/memory/voyage-api-key` から
作る（survey `deploy-recipe.summary` 2）。クライアント側は `mirror-file-memory.rb`（994 行）とそのテスト、
`cookbooks/memory-mirror`、`bin/register-memory-mirror`、`bin/register-memory-keeper` である（survey
`client-side.summary` 1）。履歴調査の範囲（13 path spec、59 ファイル・477,324 バイト）には、setup に残る recipe・
entry など 4 本と ADR 5 本（置き場所は決定事項 9）が入る。移すコードに絞ると最大 50 ファイル・395,228 バイトになる（unit・env と health のスクリプト・requirements*・eval と migrate と .pyc・hook とテストを含む上限）（survey
`history.summary`、d6d70f2 で再計測）。2026-09-28 に PVE 経由の `pct exec 119`（読み取りのみ）で、CT 119 の
`/root/setup` が 8d3b48b、`memory-mcp-v2` と `memory-v2-proxy` が active、LISTEN が `127.0.0.1:8010` と
`0.0.0.0:8767`、keeper の timer 3 本が登録済みであることを確認した。

消費者は 4 つある。

1. claude.ai の memory connector: `https://mcp.ohno.be/memory/mcp` → EC2 nginx の `location /memory/` →
   `192.168.1.83:8767` → `127.0.0.1:8010`。:8767 までは home-monitor（`devices.tf:389`、
   `scripts/mcp-proxy.conf.tftpl:171`）、:8767 から :8010 は setup の unit（`memory-v2-proxy.service:16`）が宣言する
2. ファイル記憶ミラー: pro-dev・mini の hook が Hydra client `memory-mirror` で ingest と forget を送る（neo は
   対象だが未導入、handoff:27、survey `client-side.summary` 2-3）
3. monitoring-prober: `mcp-probe/files/probe.py:62` が `/memory/mcp` を叩く。`ALLOWED_CLIENT_IDS` に載る
   `memory-keeper`（`memory-v2-proxy.service:35`）は孤立した登録で、keeper は ES に直接つなぐ（`memory-keeper/es_client.py:62`）
4. work overlay（private）の memory-work（sh1-cloud）: 同じサーバコードと hook を使う（`memory-mcp/server.py:35-37`、
   `TODO.md:1090-1094`）。取り込み方は未確認（Consequences「work overlay」）

2026-09-27 のユーザー回答で、実装を新リポ `ai-memory`（GitHub、public）へ移し、setup は取得・配置・設定の役
だけを持つことが決まった（handoff §1-§2）。setup も public なので、コードと履歴の公開範囲は変わらない（survey
`history.summary`。個人データの再掲は S5）。setup main への merge は auto-mitamae による fleet への deploy で、
ai-memory への merge は、pin なら何も deploy せず、浮動 ref を converge ごとに取得する形なら reconcile で CT 119 に
届く（loop-facts:31-32。本 ADR は SHA pin を選ぶ、Decision 8）。2026-09-28 時点で `shin1ohno/ai-memory` は存在しない
（`git ls-remote`）。2026-09-28 に、handoff §5 の 10 項目と §7 のループの形をユーザーが決めた（AskUserQuestion 3 回、
`decisions-2026-09-28.md`）。

survey `cross-refs.summary` は、ADR 0002・0003 が第 3 リポを却下済みで新リポと衝突すると指摘した（「ADR 0002・
0003 との関係」節）。選択を左右するセキュリティ上の事実は「セキュリティ上の前提」節にまとめた。

## Decision

### 1. サーバ側のアプリケーションコードを `shin1ohno/ai-memory` へ移す

移すのは memory-mcp、memory-keeper、auth-proxy、ES 索引定義である（handoff §1）。systemd unit・env と health の
スクリプト・`requirements*.txt` とクライアント側も同じリポへ移す（Decision 9）。

### 2. setup は取得・配置・設定を持つ

配置の recipe（`cookbooks/lxc-es-memory`、`cookbooks/memory-mirror`、claude-code cookbook の hook 配布）と entry
（`pve/lxc-es-memory.rb`）は setup に残る。recipe は `require_external_auth`・`systemd_unit`・`node[:setup]`・
`ssh-keys/files/aws-config.json` という setup の枠組みに依存し、新リポ単体では動かない（survey
`deploy-recipe.couplings`・`cross-refs.couplings` helper-call）。取得と配置の方式は Decision 8、setup が注入する
サイト値は Decision 9 と結合 7 のとおりである。

### 3. CT 119 に新しい資格情報を置かない

ai-memory は public なので、CT 119 は setup と同じ匿名 HTTPS で取得できる。CT 119 のディスク上にあるのは
`/root/.ssh/authorized_keys`、https の setup remote、`pve-bootstrap-ssm` プロファイルだけで、GitHub の資格情報は
無い（survey `precedents.stream_specific` §5、`auto-mitamae-target/default.rb:50`）。ただしこのプロファイルは
SSM から account-wide な GitHub 鍵を読める（S1）。本 ADR はこの経路を広げも狭めもせず、修正は別トラックで行う（S1）。

この決定の対象は、コード取得のための GitHub 資格情報である。2026-10-06 のユーザー決定により、session search のアーカイブ書き込みについてだけ例外を置く。CT 119 に専用の取得主体 `es-memory-ct119-bootstrap`（SSM `/es-memory-ct119/*` だけを読める）を置き、そこから S3 の書き込み主体 `memory-session-archive`（`sessions/*` prefix 限定）の鍵を得る。fleet 共有の `pve-bootstrap-ssm` には何も足さない（`docs/design/claude-session-search.md` §10）。

### 4. IAM 信頼境界は動かさない

IAM・KMS・SSM 書き込みの定義は home-monitor に残り、ai-memory は AWS の principal を持たない（「ADR 0002・0003
との関係」節）。

### 5. ループは L1 に L2・L3・L4・L6 を重ね、L5 も自動化する

agent-pilot の factory ループ（L1）に、L2（Linear ラベル `repo:<name>` による多リポの振り分け。team は SH1 のまま、対応表は home-monitor の中継設定に置く）、L3（blockedBy によるリポ横断の親子と pin 上げ種別）、L4（import 種別）、L6（setup にも factory）を重ね、L5（deploy 後の確認）を recall と remember の往復まで自動化する。各 L が足すものは「ループの組み合わせ（handoff §7）」節に書いた。進め方は段階的で、App と L4 → ai-memory の作成と初回 import → L2 と L3（ai-memory のタスクを Linear から流す）→ L6 と setup の切替 → L5 の順である。L5 が入るまでは、Claude が CT 119 を probe して報告し、recall はユーザーが確かめる。

### 6. agent の PR は GitHub App が開き、ai-memory では承認 1 を必須にする

所有者の PAT で開くと所有者が PR の作者になり、自分の PR を承認できない（loop-options §1 の 8、secnote:18）。App の bot が作者になれば所有者が承認でき、承認 1 が働く。App は ruleset の bypass に入れないので承認に縛られる。所有者の bypass は PR 経由に限り、main への直接 push は所有者にも許さない（S4）。App の権限・対象リポ・鍵の置き場所は実装前に adversarial review（R1）を通した（`review-r1.md`）。App は信頼段ごとに分け、sandbox 用と ai-memory 用を別に作り、それぞれ 1 リポだけに install する。承認者は `.github/CODEOWNERS`（`* @shin1ohno`）と `require_code_owner_review` で所有者に限る（App の承認は数えない）。所有者の認証情報で動く Claude が承認すると承認 1 が空になるので、ai-memory では Claude は承認せず、agent ラベルの付いた PR を bypass で merge しない。Claude が自分で開いた PR は、CI が green になってから PR 経由の bypass で Claude が merge する（2026-09-28 のユーザー決定。R1 は所有者だけが UI で merge する案を推していた）。所有者が最後に push した agent PR は、bypass せずに閉じてタスクを再実行する。

### 7. 履歴は持ち込まない（fresh、1 commit）

初回の中身は setup@SHA と (mode, OID) が一致する写しで、L4 の import 種別で入れる（決定事項 5、S5）。

### 8. 版は setup に SHA で pin し、git checkout で取得する

setup が ai-memory の 40 桁の SHA を 1 つの pin ファイルに持ち、取得と配置を 1 つの `execute` で行う。checkout は `/root/setup` の外、かつ `/opt/es-memory/app*`（retire execute が毎 converge 消す `app` と、配置先の `app-v2`）の外に置く（結合 5）。MANIFEST は converge 時に読み（結合 1）、配置先に ai-memory の SHA を書いた印（DEPLOYED_SHA）を置いて稼働中の版の正とする（handoff §9）。tag は pin に使わない（S3 (i)）。checkout の前に `$GIT_DIR/info/attributes` へ `* -text -eol -ident -filter -working-tree-encoding` を書いて変換を止め、配置した bytes の `git hash-object --no-filters` が `ls-tree` の OID と一致することを確かめてから DEPLOYED_SHA を書く。pin は ai-memory main の祖先でなければ配置しない（S3 (v)）。

### 9. unit・env/health のスクリプト・クライアント側も ai-memory に置き、サイト値は setup が注入する

unit 8 本、`generate_env_v2.sh`、`memory-keeper-health.sh`、`requirements*.txt`、hook とそのテスト、`register-memory-mirror` を ai-memory に置く。SSM パス、AWS プロファイル、ES の接続先、OIDC の issuer・audience・subject（`ALLOWED_SUBS` を含む）、配置パスなどのサイト値は setup が env で注入する。claude-code cookbook は pin した ai-memory から hook を取得して今と同じく全ホストに配り、hook の登録と本体は同じ cookbook に置く（結合 8）。

### 10. setup main には ruleset を掛けない（現状維持）

帰結は S1 に書いた。

### 11. factory のリポでは Linear の GitHub Issues 同期を切る

intake が作るミラー issue を Linear の Issues 同期が取り込み直し、影の issue を作った（sandbox のミラー #8 が SH1-11 になった）。factory のリポは Linear の GitHub 連携に残し、PR の紐付け（`Fixes SH1-N` で Linear の issue が Done になる、loop-facts:12）だけに使う。

## セキュリティ上の前提（Decision 5〜10 の根拠）

- **S1 既存の露出（setup では本 ADR の後も残る）**: fleet 各デバイスの GitHub user key（アカウント全体への push 権）は home-monitor が登録し（`ssh-devices.tf:117-120`）、秘密鍵は SSM `/ssh-keys/devices/*` にあって、fleet 共有の `pve-bootstrap-ssm` が読める（`pve-bootstrap-iam.tf:107-127`）。setup main には ruleset も branch protection も無い（2026-09-28 の読み取り probe: `gh api repos/shin1ohno/setup/rulesets` が 0 件、`branches/main/protection` が 404「Branch not protected」）。fleet のどの LXC を取られても setup main へ直接 push でき、それが fleet 全体への root での deploy になる。ai-memory を既定設定のまま作ると同じ状態を 2 つ目のリポにも作るので、ai-memory には作成時から ruleset を掛ける（S4）。setup main には ruleset を掛けない（Decision 10）ので、S1 の鍵による setup main への直接 push の経路は残る。L6 で App が開く setup の PR にも merge 前のレビューを機械的に強制するものは無く、所有者の手動 merge が唯一のレビューである（overlay の workflow には merge の手順を置かない）。self-heal-resolve の自律 merge（S3 (iii)）も残る。fleet 鍵の修正は別トラックで進める（setup `TODO.md` 先頭の項目、home-monitor の apply はユーザーの許可制）。F1 の adversarial review（`review-f1.md`）は deploy key を採らず、共有 principal の読み取りを公開鍵だけに縮め、GitHub の鍵を対話用の開発機 4 台分だけログイン鍵から切り離して作り直す案に決めた（F2 が home-monitor、F3 が setup の追従）。本 ADR の段取りはそれを待たない
- **S2 不採用にした (b) 浮動 ref の帰結**: ai-memory main への push（S1 の鍵、factory の書き込み token、loop-facts:24）が setup の commit も canary も経ずに、最長約 72 分で CT 119 へ root で載る（「反映経路の変化」）
- **S3 (a) pin が統制として効く条件**（Decision 8 はこれを前提にする）: 次のどれかが欠けると (b) に近づく。
  (i) SHA で pin する。tag を pin して git checkout で取ると、tag を動かせる者が setup の commit なしで reconcile 時に CT 119 を変えうる [推測: 取得の実装次第]。先例の roon-mcp は tag pin である（`lxc-roon-mcp/default.rb:30,146`、`#v0.5.7`）。Decision 8 は SHA に決めた。
  (ii) bump PR の差分は 40 文字の SHA だけで、ai-memory 側のコード差分がレビュー面に出ない。PR 本文に `compare/<old>...<new>` を必須にする。L3 の pin 上げ種別（`bump-pin-v1`）は、信頼されたステップが SHA を解決して compare リンクを書き、fleet deploy の経路に LLM を入れない。
  (iii) setup には人間の merge を経ない経路が既にある。self-heal-resolve は class A/B を merge まで自律で行う（`claude-code/files/skills/self-heal-resolve/SKILL.md:7,60-61`）。ai-memory の pin と MANIFEST をその対象から外す（class D 扱い、L6 の前提）。
  (iv) L3・L6 で agent が bump PR を書く場合は human merge を必須にする。setup には ruleset が無いので、これを機械的に強制するものは無い（S1）
  (v) pin は ai-memory main の祖先に限る。同じリポの未 merge のブランチにある commit も SHA で取得できるので、SHA pin だけでは未レビューの commit を指せる。`bump-pin-v1` は `git ls-remote … refs/heads/main` で SHA を解決し、CT 119 の配置（C31）と setup の CI（C33）は `git merge-base --is-ancestor <pin> refs/remotes/origin/main` で確かめる
- **S4 ai-memory の ruleset（リポ作成時に 2 段で掛ける）**: 第 1 段はリポ作成時で、ai-memory への App の install と secret の投入より前に掛ける。main への変更は PR 必須、code owner（所有者）の承認 1、所有者の bypass は PR 経由だけとし、tag は別の ruleset で作成・変更・削除を止める（承認 1 で bypass が無いと、所有者自身の PR が merge できない。loop-options §1 の 8）。承認 1 が縛るのは所有者以外が作った PR で、承認者は code owner に限る（Decision 6）。第 2 段は初回 import の後で、`guard` と CI の job（`ai-memory-ci`）を required checks にする bypass の無い別の ruleset を足す（import 前の main には対象ファイルが無く CI が通らないので、先に足すと scaffold の PR を merge できない）。CT 119 が ai-memory から取得を始めるのは setup の切替からなので、両段ともそれより前に入る。ruleset の変更には Administration 権限が要り、user key（git 操作のみ）も App（Administration を持たせない、R1）もそれを持たない [推測: GitHub の権限モデルからの推論、未実測]。S1 の鍵による直接 push は第 1 段で止まる
- **S5 個人データ**: unit の `ALLOWED_SUBS` に個人メール 2 件（`memory-v2-proxy.service:32`、値は伏せる）、テストにメール 1 件、`eval/golden_set.jsonl:1-3` に身体属性がある（survey `runtime-code.risks`）。setup で既に公開済みである。fresh（Decision 7）なので setup の履歴は持ち込まないが、初回 import は setup@SHA と同一なので、unit とテストのメールは ai-memory にも載り、サイト値を注入へ移した後も ai-memory の履歴に残る。身体属性を含む `eval/golden_set.jsonl`（38 行中 3 行）と `eval/reconcile_cases.jsonl`（20 行中 5 行）は import の対応表から外し、2 つ目の public リポには載せない（決定事項 6）
- **S6 資格情報**: 計画全体で新設・変更されるものは Consequences「新規・権限変更される資格情報」に並べた

## 決定事項（2026-09-28）

handoff §5 の 10 項目は次のとおり決まった（`decisions-2026-09-28.md` の R1-Q3・R1-Q4・R2-Q5・R2-Q8・R4-Q1）。ループ・PR の
作者・setup の ruleset・Issues 同期・進め方は Decision 5〜11、fleet 鍵は S1 に書いた。

| # | 問い | 決定 | 理由（1 行） |
|---|---|---|---|
| 1 | 版の取得 | SHA を pin する（Decision 8） | S2 の経路を閉じ、起点が setup の commit 1 つに保たれ、pin した SHA が setup の履歴に残る。tag pin は tag を動かせる者に経路を開く（S3 (i)）。代償は 1 変更あたり PR 2 本と S3 の運用条件 |
| 2 | 配布形式 | pin した SHA の git checkout + ファイル配置。取得と配置は 1 つの `execute`、checkout は `/root/setup` と `/opt/es-memory/app*` の外（Decision 8） | release workflow が要らず CT 119 は匿名 HTTPS で読める。wheel は keeper が prompts を `__file__` 相対で読む（`reconcile.py:40`、`consolidate.py:58`）ので flat py-modules では配れず、PyPI の公開トークンも要らない。結合 1・2・5 はこの形で解く |
| 3 | unit 8 本・`generate_env_v2.sh`・`memory-keeper-health.sh`・`requirements*.txt` の置き場とサイト値 | ai-memory に置き、サイト値は setup が env で注入する（Decision 9） | 4 スイートが無修正で動き（結合 3）、requirements がコードと同じリポにあるので依存より先に新しい版が届く crash-loop（ADR 0010:43-46 の型）を避ける。今の直書き（`generate_env_v2.sh:30,34`、`memory-v2-proxy.service:11-12,27,32,35`）は注入へ移し、health の metric 名は lxc-monitoring の alert との契約として残る |
| 4 | クライアント側（hook・テスト・`register-memory-mirror`）の置き場 | ai-memory。claude-code cookbook が pin した ai-memory から hook を取得して配る（Decision 9） | 契約定数（結合 6）をサーバと同じ PR で変えられ、hook の変更もループに載る。hook は memory-work も使う（survey `client-side.open_questions`）ので W0 が前提（決定事項 7） |
| 5 | 履歴 | fresh（1 commit、Decision 7） | 履歴を入れるには main への直接 push か rebase merge が要り handoff §10 とぶつかる。filter-repo（13 spec で 35 本、移すコードに絞ると 29）も subtree split（30）も全 commit が squash merge で `(#N)` と gpgsig を持ち、パスを絞ると gpgsig は無効になり、履歴に S5 の個人データも入る。`(#N)` の書き換えと Co-Authored-By trailer（11 commit・21 行）の除去も不要になる |
| 6 | legacy の扱い | 新リポに移さず、setup の切替（W7）で runtime コードと同じ削除 PR で消す。対象は `migrate/`、壊れた `eval/eval_reconcile.py`、追跡された `.pyc`、`register-memory-keeper`、v1 の retire execute。`eval/` はデータ 2 本（`golden_set.jsonl`・`reconcile_cases.jsonl`）も身体属性を含むので移さず、`eval_recall.py` だけを移す（`GOLDEN_SET` でリポ外のファイルを読む。データは setup の履歴から取り出せる）。孤立した Hydra client `memory-keeper` と SSM `/memory/keeper-client-*` の削除は別に承認を取る | fresh import なので持ち込まずに済む。`migrate/` は削除済みの v1 索引を、`eval_reconcile.py` は存在しない関数を参照し、`register-memory-keeper` が書く secret を読むものは無い（secret を argv に載せる欠陥もある）。Hydra と SSM を消す前に `ALLOWED_CLIENT_IDS`（`memory-v2-proxy.service:35`）と `CLIENT_POLICY`（`memory-mcp-v2.service:34`）から同じ PR で外す |
| 7 | work overlay の memory-work を範囲に入れるか | 入れない。ただし setup からの削除は memory-work の消費を確かめる（W0）まで待つ | zp-SHIN の clone が無く取り込み方を確かめられない。setup のパスを直接読んでいれば削除で本番の store が止まる（「work overlay」節） |
| 8 | ADR 0010「次の段」の時期 | 分割後に ai-memory で行う | W5 としてループに載る（loop-options Q8 の既定値）。`server.py` は import 時に ES へ接続し（ADR 0010:43-46）、次の段 1 は次の段 2 の公開 API 往復テストの前提になる（0010:69-70） |
| 9 | 文書の置き場 | ADR 0007・0008 は ai-memory へ移し、0010 は setup に残して次の段を ai-memory へ引き継ぐ。`knowledge-persistence.md:17-25` はポインタにする | 0007・0008 は memory-v2 の振る舞いの決定で、0010 は cookbook が読む MANIFEST と新リポの作業順にまたがる。同節は常時ロードの doctrine で hook のパスを名指しする（survey `client-side.couplings` docs-link） |
| 10 | 開発機への自動 clone | `roles/manage/files/repositories.json`（14 件）に足す | 足さないと開発機の `~/ManagedProjects` に clone されない（survey `precedents.couplings` docs-link）。weave と roon-rs も同じ一覧にある |

## ADR 0002・0003 との関係

ADR 0002 は「**コード (Ruby helper / Terraform module) を含む第 3 リポは却下**」とした（0002:16）。対象は
Identity & Access（host registry、IAM 定義、Tailscale ACL、SSH 鍵 SSM 定義）を `home-identity` へ切り出す案で
（0002:8）、理由は push 権限保有者が「IAM principal 新規作成 / credential SSM 投入 / cookbook 経由 LXC 展開 を
1 PR で実行可能」になる privilege aggregation だった（0002:34-38）。ADR 0003 は「**`home-monitor` と `setup` の
リポジトリ境界 = AWS IAM 信頼境界として扱う**」とし（0003:11）、第 3 リポを「自動的に却下」したうえで（0003:30）、
不変条件を 4 つ置いた（0003:40-43）。

| 観点 | `home-identity`（ADR 0002 が却下） | ai-memory |
|---|---|---|
| 中身 | IAM principal 定義、Tailscale ACL、SSH 鍵の SSM 定義、host registry、Ruby helper、Terraform module | Python アプリ、ES 索引 JSON、unit とスクリプト、hook（Decision 9）。`aws iam`・`aws kms`・`put-parameter` の `git grep` は `cookbooks/lxc-es-memory` で 0 件（8d3b48b） |
| 境界の中の位置 | home-monitor と setup を統合する層 | setup の下流にあるアプリ 1 つ。roon-rs・weave と同じ位置（survey `precedents.stream_specific` §1 A・B） |
| merge で起きる credential 発行 | IAM principal・SSM secret・LXC 展開が 1 PR で起きる | 起きない。SSM に書くのは operator が PutParameter を持つ profile で手で実行するスクリプト（`bin/register-memory-{mirror,keeper}`、`bin/issue-apm-api-keys.sh:32-37,77-86`）だけで、`register-memory-mirror` は Hydra client も作る（`POST /admin/clients` は `:127`、SSM への書き込みは `:142-147`）。merge を契機に走るものは無い |
| CT 119 の AWS 権限 | — | `pve-bootstrap-ssm`（`/ssh-keys/devices/*`・`/monitoring/{elastic,apm}/*`・`/hydra/*`・`/memory/*` の読み取り、home-monitor `pve-bootstrap-iam.tf:107-227`）のまま。`/ssh-keys/devices/*` から account-wide な GitHub 鍵に届く経路は既にあり（S1）、切り出しはこれを広げも狭めもしない |

IAM 信頼境界は動かない。cookbook は setup に残り AWS 側を変えないので、ADR 0003 の不変条件 1〜3（cookbook は
`aws iam`・`aws kms`・`ssm put-parameter` を呼ばない、Terraform state に cookbook の identity が届かない、
`pve-bootstrap-ssm` に PutParameter を足さない）は保たれ、4（`setup_ci_ssm_reader`）にも触れない。移すテスト 4 本は
AWS の資格情報を持たない `syntax-check` job で走る（`test-setup.yml:522`。OIDC は `ssm-validation` job だけ、`:733-744`）。

ADR 0002 の懸念が ai-memory に当てはまるには、次のどれかが成り立つ必要がある。

1. ai-memory が IAM・KMS・SSM 書き込みの定義を持つか、merge を契機にそれを実行する。現状はどちらも無い
2. ai-memory への push だけで fleet ホストに root でコードが載る。Decision 8 の SHA pin では単独では起きない（setup の
   bump commit が要る）が、bump の統制は S3 の条件にかかる。不採用にした (a') tag pin は tag を動かせる者に経路を
   開きうる。同じく不採用の (b) なら reconcile で CT 119 に載り、ADR 0002 が setup について書いた「cookbook write 権限 (LXC RCE
   等価)」（0002:23）を 2 つ目のリポへ広げる。push できる主体は S1 の user key と factory の書き込み token
   （loop-facts:24、Decision 6 で App に置き換える）で、同じ権限は setup について既に fleet 全体へ広がっている（S1）
3. Hydra client や SSM secret の宣言を ai-memory が持つ。現状 client はどのリポにも宣言されていない（survey
   `client-side.summary` 4）。Decision 9 で `register-memory-mirror` を移すので credential を作る手順は ai-memory に
   入るが、実行は PutParameter を持つ operator の手作業のままである。L5 の probe client の登録も同じく人の手作業である

ADR 0002 のセキュリティ上の懸念（IAM の privilege aggregation）は ai-memory に当てはまらない。deploy 権限の広がりは
主に版の取得方式で決まり、Decision 8 の SHA pin でも S3 の条件と S4 の ruleset が要る。運用面の懸念（release
ordering、multi-repo の認知負荷、fork 化、3 つ目の clone。0002:22-24,40-44）は一部が当てはまる。

ADR 0002 と 0003 の決定は変更しない。ただし `CLAUDE.md:163`（「廃案: …第 3 リポ抽出 (privilege aggregation
anti-pattern)」）と ADR 0003:30 は無条件に読め、後続のセッションや auto-mode の classifier はルール文をそのまま
引く（`.claude/rules/infrastructure.md`「Auto-Mode Classifier Boundary」末尾）。本 ADR と同じ変更で `CLAUDE.md:163`
へ「アプリだけのリポは ADR 0013 で対象外」と注記し、ADR 0002・0003 の Status 行に ADR 0013 への参照を足した。

## ループの組み合わせ（handoff §7）

選んだ組み合わせは L1 + L2 + L3 + L4 + L5 + L6 である（Decision 5。比較は `loop-options.md`）。実装前の adversarial review は R1（App・L4・保護リスト・public リポの脅威）、R2（L2・L3・pin 上げ）、R3（setup の L6）、R4（L5）の 4 回で、コードは review の後に書く。各 L が足すものは次のとおりである。

- **L1**: ai-memory に factory の overlay と secret が入る（「新規・権限変更される資格情報」）。ai-memory への書き込みは次の pin 上げで CT 119 の root 実行になる（loop-options 安全 1）ので、S4 の ruleset と承認 1（Decision 6）が前提になる。pin なので App の書き込みは setup の pin 上げまで CT 119 に届かない。public リポで外部者が起こす issue と fork の脅威は secnote に書かれていない（fork への言及は secnote:75 だけ）ので、R1 で扱う
- **L2**: 中継が Linear ラベル `repo:<name>`（ちょうど 1 つ）で振り分け、経路ごとの PAT で各リポの intake を dispatch する。対応表は home-monitor の中継設定に置き、apply はユーザーの許可制である。setup の経路の token は R3 の後にだけ作り、factory のリポでは Issues 同期を切る（Decision 11）
- **L3**: blockedBy で親子を張り、親が Done になると中継が待機中の子の経路へ並列に dispatch する（Lambda の 4 秒の制限内）。「pin を上げる」は決定的な `bump-pin-v1` 種別で、書き先が setup なので L6 が要る。bump PR は S3 (ii)・(iv) に従う
- **L4**: import の envelope では agent を起動しない（2026-09-28 のユーザー決定、R1 の D1）。信頼されたジョブが allowlist のリポを 40 桁の SHA で fetch し、その SHA が既定ブランチの祖先であることを確かめ、`git ls-tree` の entry（mode 100644・100755 の blob だけ）を `git update-index --cacheinfo` で対応表どおりの path に置いて commit を組み立てる。commit 後にもう一度 (mode, OID) を照合し、1 つでも違えば PR を出さない（安全 3）。agent が import 領域を読まないので、指示ファイルの除去（安全 2）は不要になる。allowlist に無いリポ、tag・branch の ref、symlink と submodule の entry は拒否する。allowed_paths が空だと T1・T2 のタスクが認証のファイルに触れられるので、リポごとの保護リスト `.github/agent-protected.txt`（ai-memory では `proxy.py`・`identity.py`・`policy_mcp.py` と unit 2 本）を先に入れる
- **L5**: pro-dev の runner が pin 上げの後に CT 119 の 4 点（handoff §9）を確かめ、recall と remember まで往復させる。CLIENT_POLICY の文法は ingest と forget しか許さない（`identity.py:203,288-292`、`memory-mcp-v2.service:27`）ので、identity.py の認可モデルを変える。recall は dataset で絞れないので全 memory を読める Hydra client が 1 つ増え、client id が 3 リポ契約（結合 7）に 1 つ増える（loop-options 安全 4）。secret は pro-dev だけが読めるように置き、R4 の adversarial review と実トークンの往復確認を必須にする。runner を CT 119 に置かないのは Decision 3 のため
- **L6**: setup にも factory を入れる（T3）。setup の merge は fleet deploy で、App の setup への Contents 書き込みは ADR 0002:23 の「cookbook write 権限 (LXC RCE 等価)」そのものなので、App が開く setup の PR が fleet deploy の経路になる。setup main には ruleset を掛けないので（Decision 10）、所有者の手動 merge だけがレビューである（S1）。前提は、ADR 0003 不変条件 1 の lint 検査（`bin/lint-cookbooks` は未検査、loop-options §3 L6）、self-heal-resolve が pin と MANIFEST を class D として扱うこと（S3 (iii)）、setup の保護リスト、overlay の workflow に merge の手順を置かないことである。setup 用の App と secret は R3 で決める

## Consequences

### 分割で壊れる 8 つの結合と解き方の選択肢

file:line は setup d6d70f2 のもの。d6d70f2 から 8d3b48b までのリポ全体の差分は `.claude/rules/shell.md` と
`claude-code/files/rules/ask-user-question.md` の 2 本だけで、本 ADR が引くファイルは含まない。

| # | 結合 | 壊れ方 | 解き方の選択肢 |
|---|---|---|---|
| 1 | `lxc-es-memory/default.rb:213-216`・`417-419` が MANIFEST を compile 時に `File.read` する | converge 時の git fetch では、新規ホストで compile が失敗し、既存ホストには 1 つ前の版の一覧が配られる | (a) 取得を前段のプロセスへ移す。ADR 0012 の bootstrap に似るが、0012 は Proposed で、bootstrap は対話用の `bin/converge` にしか無く、fleet の runner は `./bin/mitamae local "$role"` を直接呼ぶ（`mitamae-runner.sh:308`）。hosts.json の全 18 ホストの runner 変更か ADR 0012 の改訂が要り、ADR 0009 の状態管理にも触れる (b) MANIFEST を compile 時に読まず、取得物を 1 つの `execute` で丸ごと置く (c) wheel を pip install する（決定事項 2 で不採用） (d) pin を上げるときに MANIFEST だけを setup へ vendoring する（survey `precedents.stream_specific` §1 I 型）。配布物そのものの vendoring は handoff §9「setup に runtime コードが残っておらず」と矛盾する |
| 2 | `bin/lint-cookbooks` の check 15 | `sensitive true` の無い placement のうち、source が `files/`・`templates/` 以外のものは secret 扱いで FAIL になる（`lint-cookbooks:94-108,1107,1191`） | (a) 宣言した checkout root を REPO_SOURCE に加える（secret 検査が信頼する範囲を広げる） (b) placement ごとに理由付きで `SENSITIVE_EXEMPT` に足す (c) コードの配置を `execute` にする（check 15 の対象外。`.claude/rules/ruby.md`「Secret-bearing placements」） (d) `sensitive true` を付ける（コードの差分がログに出なくなる） |
| 3 | `test_client_policy.py` が `../systemd/*.service` を読み（`:48,72,563`）、`test_merge_rules.py` が `../memory-mcp/identity` を import する | unit とコードが別リポになるとテストが入力を失う | (a) `memory-mcp/`・`memory-keeper/`・`systemd/` を ai-memory で兄弟のまま置く（4 本が無修正で動く、survey `runtime-code.summary` 2） (b) unit を setup に残し、setup の CI が pin した ai-memory を取得してテストを回す (c) テストが読む値を fixture に切り出し、setup 側で unit との一致を別に検査する |
| 4 | `bin/check-memory-v2-manifest:26` の BASE、`test-setup.yml:592-663` の 6 step、mirror hook の step（`:675-683`）がパスを直書きする | ファイルが消えると CI が ENOENT で落ち、ADR 0010 の「配布物そのものを検証する」保証がどちらのリポでも成り立たなくなる | (a) 検査を ai-memory の CI へ移し、setup には pin した ref の取得と配布契約の検査を置く (b) BASE を引数にし、setup の CI が pin した checkout に対して走らせる (c) (a) と (b) の両方 |
| 5 | runner が毎サイクル `/root/setup` で `git reset --hard` と `git clean -fdq` を実行する（`mitamae-runner.sh:190-191`） | `/root/setup` の下に置いた .git を持たない展開物（tarball・sdist）は毎サイクル消える。入れ子の git checkout は単一の `-f` では残るが（git 2.47.3 の scratch で再現。CT 119 の git 版は未測定 [推測: 同じ挙動]）、setup の untracked として残り、`-f` を 2 つ重ねる（`-ff`）と消える（`-x` だけでは消えない） | (a) 取得物を `/root/setup` の外に置く。`/opt/es-memory/app` と `/opt/es-memory/es-indices` は retire execute が毎 converge `rm -rf` するので使わない（`lxc-es-memory/default.rb:144-151`） (b) tarball か wheel を `/root/setup` の外へ展開・install する |
| 6 | クライアントとサーバの契約定数が分かれて置かれる。サーバ側は `policy_denied:`・45000 が `identity.py:207,222`、audience・client_id が unit（`memory-v2-proxy.service:27,35`、`memory-mcp-v2.service:34`）、TTL 3600 が Hydra（setup の `lxc-hydra/files/hydra.yml:59`）。hook 側は `mirror-file-memory.rb:114,130,219,231-238,860` | サーバ側と hook を 1 PR で変えられなくなる。サーバが上限を下げると、hook は送ってから拒否される。TTL は hook と setup の lxc-hydra の間で閉じるので、分割後も 1 PR で変えられる | (a) hook も ai-memory に置き、同じ PR で変える（決定事項 4） (b) hook を setup に残し、setup の CI で pin した `identity.py`・unit と hook の定数を照合する（TTL は setup 内で照合する） |
| 7 | ai-memory・setup・home-monitor の 3 リポにまたがる契約（次の表） | 片側だけの変更が、connector の 502/404、alert の無効化、外形監視の脱落、SLM バックアップからの脱落を黙って起こす | (a) 契約の値を ai-memory の文書に interface として宣言し、setup と home-monitor が参照する (b) サイト値を setup が持ち、unit へ env で注入する（決定事項 3 と組む） (c) pin を上げる PR で setup の CI が値を照合する（ADR 0004 の jq sanity check と同じ形） |
| 8 | hook の settings.json 登録（`claude-code/files/settings.json:130,146`）と本体の配置（`claude-code/default.rb:241`） | 分かれると、登録だけあって本体が無いホストができる。`hooks` キーは shallow merge なので、登録を別の cookbook に分けられない（survey `client-side.couplings` path-contract） | 制約: 登録と本体は同じ cookbook に置く。(a) claude-code cookbook が pin した ai-memory から hook を取得し、今と同じく全ホストに配る (b) hook を claude-code cookbook に残す（決定事項 4 で不採用） (c) memory-mirror cookbook が mirror 対象ホストにだけ置く（claude-code の merge 方式の変更が前提） |

採る解き方は 1(b)・2(c)・3(a)・4(c)・5(a)・6(a)・7(b)・8(a) である（Decision 8・9）。1・2・5 は取得と配置を 1 つの `execute` にまとめて checkout を `/root/setup` の外に置く形で、4 は ai-memory の CI の配布物検査と、BASE を引数にした `check-memory-v2-manifest` を setup の CI が pin した checkout に対して走らせる形で解く。

3 リポにまたがる契約（結合 7）は次のとおりである。「アプリ側」は今の `cookbooks/lxc-es-memory/files/` 配下の
定義箇所で、決定事項 3 によりファイルは ai-memory へ移り、サイト値は setup が注入する。

| 契約 | 値 | アプリ側 | setup の相手先 | home-monitor の相手先 |
|---|---|---|---|---|
| 公開ポートと prefix | `8767`、`/memory` | `memory-v2-proxy.service:16-17,22`、`proxy.py:399` | — | `devices.tf:389`、`mcp-proxy.conf.tftpl:171` |
| health パス | `/health` | `auth-proxy/proxy.py:218` | `lxc-monitoring/files/prometheus.yml:257-263`（blackbox が `https://mcp.ohno.be/memory/health` を probe） | nginx の `location /memory/`（`mcp-proxy.conf.tftpl:171`） |
| node_exporter の scrape | `192.168.1.83:9100`（keeper-health の textfile が載る） | `memory-keeper-health.sh` | `prometheus.yml:165-171`（`node-es-memory`） | `contracts/devices.json` の .83 |
| SSM パス | `/monitoring/elastic/elastic-password`、`/memory/voyage-api-key`、`/memory/mirror-client-*` | `generate_env_v2.sh:30,34` | `memory-mirror/default.rb:140-153`、`register-memory-mirror:50-51` | `pve-bootstrap-iam.tf:135-151`（`/monitoring/elastic/*`）、`:201-227`（`/memory/*`）。voyage key は Terraform 外 |
| 索引名と analyzer | `memory-*`、kuromoji | `es-indices-v2/*.json` | `lxc-elasticsearch/default.rb:180-199`、`snapshot-bootstrap.sh:234`（SLM） | — |
| metric 名 | `memory_keeper_raw_backlog`、`memory_keeper_stats_age_seconds` | `memory-keeper-health.sh` | `lxc-monitoring/files/alerts/memory.yml:35,54,74,94` | — |
| client id | `memory-keeper`（孤立）、`monitoring-prober`、`memory-mirror` | `memory-v2-proxy.service:35`、`memory-mcp-v2.service:34` | `bin/register-*`、`mcp-probe/files/probe.py:62` | Hydra の DB（Aurora、`hydra.tf:32-43`）にだけ存在し、どのリポにも宣言が無い |
| OIDC | issuer `https://mcp.ohno.be`、audience `https://mcp.ohno.be/memory`・`memory` | `memory-v2-proxy.service:11-12,27` | `lxc-hydra`（`hydra.yml:59`、TTL 1h） | `mcp-proxy.conf.tftpl:120-139` |
| APM サービス名 | `ai-memory-auth-proxy` | `auth-proxy/proxy.py:38` | `bin/issue-apm-api-keys.sh:36` | — |
| 配置パス | `/opt/es-memory/keeper-claude.env`、`CLAUDE_BIN` | `memory-keeper-reconcile.service:19,30-32` | `bin/doctor:190-200`、`lxc-es-memory/default.rb:394-397,456-460` | — |

### 反映経路の変化

今の起点は setup main の SHA だけである。drift-checker は `git ls-remote` で setup main を見て
（`drift-checker.sh:19,29`）、runner は SHA が変わると即 converge し、それ以外は 3600 秒 + ホストごとの jitter で
reconcile する（`mitamae-runner.sh:110-111`）。jitter は role パスの cksum で固定され（`:272-276`）、CT 119
（`pve/lxc-es-memory.rb`）は 405 秒なので約 67 分ごと、orchestrator の 5 分周期を足して最長約 72 分になる（fleet
全体の上限は約 2 時間）。ai-memory の commit はこの起点を動かさない（survey `deploy-recipe.summary` 4）。Decision 8
は次の表の (a) の SHA pin である。

| | (a) SHA pin・(a') tag pin | (b) 浮動 ref を converge ごとに取得 |
|---|---|---|
| ai-memory への merge | 何も deploy しない（(a') は tag の扱い次第、S3） | CT 119 の次の reconcile（最長約 72 分後）で載る |
| setup への merge | pin を上げる commit が即時の converge を起こす | ai-memory の版は変わらない |
| canary（pro-dev） | gate は動くが、pro-dev は lxc-es-memory を include しない（`hosts.json:10,18`、`pve/lxc-pro-dev.rb:187` は memory-mirror だけ）ので server 側の変更は検証しない。client 側は Decision 9 で移すので、hook の配布は pro-dev で一部検証される | 通らない |
| SHA 単位の apply 状態（ADR 0009） | setup の SHA として残る | 残らない |
| 稼働中の版の観測 | apply-state は setup の SHA で、converge が途中で失敗すると配置物と食い違う（`mitamae-runner.sh:112-119`）。配置先に ai-memory の SHA を書いた印を置き、それを正とする（handoff §9） | setup からは見えない。同じ印が要る |
| 1 変更あたりの PR | ai-memory と setup の 2 本 | ai-memory の 1 本 |

(b) の先例は edge-agent（C 型、`edge-agent/common.rb:19,36-39` の `@latest`）と git_clone + pull（E 型）である。
weave（B 型、`lxc-weave/default.rb:37-38`）も main を追うが、image tag `:main` が自分自身と一致して再ビルドしない
ので（`functions/default.rb:720-721`）、compose ファイルが変わるまで届かない（survey `precedents.stream_specific`
§1 B・C・E）。浮動 ref でも取得の仕組み次第で更新が永久に届かない。canary が CT 119 を検証しないので、切替の条件は
CT 119 上の機能 probe（handoff §9 の 4 点目）である。L5 が入るまでは Claude が probe して報告し、recall はユーザーが
確かめる（Decision 5）。

取得の先例はどれも GitHub の REST API（未認証は IP あたり 60 回/時）を経由せず、固定 URL の `releases/download/`
と sha256（herdr・node_exporter）か `git ls-remote`（`drift-checker.sh:5`）を使う（survey `precedents.stream_specific` §1 D）。

### 切替とロールバック

今の配置は MANIFEST の各ファイルを `remote_file` で足すだけで、MANIFEST から消えたファイルを消さない
（`lxc-es-memory/default.rb:213-225,417-424`）。手順は次のとおりで、振る舞いの変更は切替と別の PR にする。

1. ai-memory を作り（S4 の第 1 段）、初回 import、CI、S4 の第 2 段を整える
2. setup の配置元を pin した ai-memory へ切り替える PR を、setup 同梱と内容が同一の版で出す（setup HEAD と ai-memory@pin の (mode, OID) の差分が 0）。pro-dev の canary は CT 119 を通らないので、orchestrator を止めて CT 119 にだけ切替の枝を当て、配置ファイルの sha256 を前後で比べる（差 0）。その後 CT 119 の機能 probe（handoff §9 の 4 点）を通す
3. 「work overlay」節の前提（W0）を満たしてから、setup の複製を消す PR を出す

切替 PR を revert すると、次の converge で setup 同梱のファイルが上書きされるが、ai-memory の版で増えたファイルと
取得物は残る [推測: 取得の実装次第]。ADR 0010 の次の段は分割後に ai-memory で行う（決定事項 8）ので、切替時の
ロールバックは setup の複製を消す前（手順 3 の前）の revert である。次の段 3（版別ディレクトリ、`0010:74-75`）が
入れば、以後のロールバックは参照先の付け替えで済む。

### 新規・権限変更される資格情報

| 資格情報 | 変化 | 生じる条件 | 根拠 |
|---|---|---|---|
| CT 119 | なし | public のまま（Decision 3） | handoff §2 |
| GitHub App 2 つ（`shin1ohno-factory-sandbox` は sandbox だけ、`shin1ohno-factory-ai-memory` は ai-memory だけに install）と、それぞれの秘密鍵 | 新規。PR を開き、ラベルを付け、fix の commit を push する token を、job ごとに 1 リポ・1 権限で発行する。権限は contents・pull_requests・issues の write と metadata の read だけで、Workflows・Administration・Variables は持たない。ai-memory の鍵は `main` だけが使える environment `agent-app` の secret、sandbox（private の Free プランで environment secret が使えない）は repository secret | L1（Decision 6） | `review-r1.md` §2(a)、issue-tree C04・C09 |
| リポごとの `GH_AW_CI_TRIGGER_TOKEN`（Contents・PR の RW）と `GH_DISPATCH_TOKEN`（issues:write） | ai-memory には作らない。App の installation token で代える（App の変数が無いリポは従来の PAT に戻る） | L1 | loop-facts:24-25、issue-tree C09 |
| `CLAUDE_CODE_OAUTH_TOKEN`・`LINEAR_API_KEY` | ai-memory 専用に新しく発行し、`main` だけが使える environment（`agent-claude`、C18 で `agent-linear`）の secret に置く。repository secret は 0 本。setup-token が claude.ai の connector に届くかを先に probe し、届くなら public リポに置くかどうかをユーザーに戻す | L1・L2 | `review-r1.md` §2(a)・PUBLIC-1、loop-options 安全 5 |
| 中継の PAT（今は SSM `/agent-pilot/linear-forwarder/github-token`、sandbox 1 リポの Actions RW） | 経路ごとに 1 本（Actions RW を 1 リポずつ、SSM の経路別パラメータ）。中継は App を使わず PAT のまま | L2 | loop-facts:17,27、handoff §10 |
| setup の経路の中継 PAT、setup 用の App と setup の secret | 新規。R3 の後にだけ作る。setup の Contents 書き込みは LXC RCE 等価（ADR 0002:23） | L6 | R3 |
| probe 用 Hydra client（recall・remember を往復でき、全 memory を読める。secret は pro-dev だけが読める） | 新規。identity.py の認可モデル変更を伴い、`CLIENT_POLICY` の値も増える | L5（Decision 5） | loop-options §2 L5 行・安全 4、R4 |
| Linear の GitHub 連携 | ai-memory を加え、Issues 同期は切って PR の紐付けだけに使う | L2（Decision 11） | R2 |

どの行も実装前に adversarial review（R1〜R4）を通し（handoff §10）、home-monitor の apply はユーザーの許可を得てから行う。孤立した Hydra client `memory-keeper` と SSM `/memory/keeper-client-*` の削除も、その都度ユーザーの承認を取る（決定事項 6）。

### CI の変化

- setup から消えるもの: `syntax-check` job の memory 系 6 step（`test-setup.yml:592-663`）。クライアント側も移す
  （Decision 9）ので mirror hook の step（`:675-683`）も消える
- ai-memory に作るもの: 4 テストスイート（17・45・111 + skip 1・29 件、survey `runtime-code.summary` 2）、配布物の
  import 検査（ADR 0010 Decision 2）、proxy の import テスト（handoff §9）。S4 の第 2 段が `guard` とこの CI の job を
  required checks にする
- setup に残るもの: `bin/lint-cookbooks`・`bin/audit-cookbook-reachability`・`ruby -c`（survey `cross-refs.couplings`
  ci-job）。Decision 8 により、pin した ref の実在と配布契約を確かめる検査も置く（survey `precedents.couplings` ci-job）

### work overlay（未確認）

work overlay（private）は memory-work（sh1-cloud）で同じサーバコードを動かし（`memory-mcp/server.py:35-37`）、
claude-code cookbook が配る hook を server-name 形式の config で使う（survey `client-side.couplings` deploy-trigger）。
overlay の clone は pro-dev にも mini にも無く、work Mac には ssh で届かず、sh1-cloud は pro-dev から名前解決できない
（2026-09-28、`ssh sh1-cloud` が Could not resolve hostname）。overlay がサーバコードを setup のパスから読むなら、
setup からファイルを消すと memory-work が壊れる [推測]（survey `cross-refs.couplings` file-read）。hook の変更も波及する。

前提条件: overlay を clone できるホストで取り込み方を確認するまで（handoff §8-2、W0）、setup の対象ファイルを消す
PR と hook の取得元の切替は出さず、長引くなら互換用の複製を setup に残す。memory-work は範囲外と決めたが（決定事項
7）、この前提は残る。

### そのほかの帰結

- setup は public のままでなければならない。fleet は setup を匿名 HTTPS で取得・監視している
  （`auto-mitamae-target/default.rb:50`、`drift-checker.sh:19`）
- 13 spec の外で memory 系の名前に当たる setup の tracked ファイルは 33 本ある（survey `cross-refs.summary` の 46 は
  `lxc-es-memory/files` の外の数で 13 spec の 13 本を含む。d6d70f2 で再計測）。移したファイルへの参照が 0 件で
  あることは、positive control 付きの grep で確かめる（handoff §9）
- 移したファイルに紐づく TODO は ai-memory 側へ移し、setup の `TODO.md` から消す（handoff §9）

## Rejected alternatives

- **private リポ**: CT 119 に初めて GitHub の資格情報を置くことになる。既存の user key `tf-device-es-memory` は
  アカウント全体への書き込み権を持ち、fleet のどの LXC からも取得できる（S1、survey `precedents.couplings`
  ssm-param）。2026-09-27 のユーザー回答で public に決まった（handoff §2）
- **cookbook ごと ai-memory へ移す**: recipe が setup の helper・host-profile・aws-config に依存し、新リポ単体では
  動かない（survey `cross-refs.couplings` helper-call）。setup を取得・配置の役に残す決定（handoff §1）とも合わない
- **浮動 ref（main）を converge ごとに取得**: ai-memory への push が canary も setup の commit も経ずに CT 119 へ root で載る（S2）
- **tag pin・release tarball・wheel**: tag は動かせる者に経路を開き（S3 (i)）、tarball は release workflow を、wheel はパッケージ構成の変更を先に要する（決定事項 2）
- **履歴を持ち込む（filter-repo・subtree split）**: main への直接 push か rebase merge が要り、gpgsig は無効になり、S5 の個人データも入る（決定事項 5）
- **所有者の PAT で agent の PR を開く**: 所有者が作者になり承認 1 が効かないか、所有者を bypass に入れて実質承認 0 になる（Decision 6）。machine account の classic PAT も承認は効くが、アカウントと PAT の期限の管理が増え、L2 でリポが増えるなら App が有利である（loop-options §6 Q6）
- **setup main に ruleset を掛ける**: 所有者を bypass に入れないと self-heal-resolve の自律 merge が止まり、所有者の認証で開いた PR は承認もできない。bypass に入れると所有者の一存で merge でき、掛けないのと実質同じになる（loop-options §6 Q10）。ユーザーは掛けないことを選んだ（Decision 10、帰結は S1）

## References

- ADR 0001（モノレポ却下）、0002（第 3 リポ却下）、0003（IAM 信頼境界 = リポ境界）: 決定は変更しない（注記の追加は
  「ADR 0002・0003 との関係」末尾）。ADR 0004（host registry の SSM 配送。リポ横断契約の型付けの先例）
- ADR 0009（SHA 単位の apply 状態）、0010（memory-v2 の配布単位と「次の段」）、0012（compile と converge の順序、Proposed）
- 調査: `~/.claude/plans/ai-memory-extraction-2026-09-27/survey.json`（setup d6d70f2、home-monitor 00e3e84、
  2026-09-27。本 ADR が引く home-monitor のファイルは 9425148 まで差分なし）、同ディレクトリの `handoff-prompt.md`・
  `loop-facts-2026-09-28.md`・`loop-options.md`（§7 の比較）
- 決定と計画: 同ディレクトリの `decisions-2026-09-28.md`（ユーザーの決定 11 件）と `issue-tree.md`（Linear の子
  C01〜C48・F1〜F3）、`~/.claude/plans/functional-painting-firefly.md`（承認済みの計画）
