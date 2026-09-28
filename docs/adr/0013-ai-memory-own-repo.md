# ADR 0013: ai-memory（memory-v2）を独立リポ `shin1ohno/ai-memory` へ移し、setup は取得・配置・設定を持つ

**Status**: Proposed（draft、2026-09-28）

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
entry など 4 本と未決事項 9 次第の ADR 5 本が入る。移すコードに絞ると最大 50 ファイル・395,228 バイトになる（置き場所が未決の unit・env と health のスクリプト・requirements*・eval と migrate と .pyc・hook とテストを含む上限）（survey
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
届く（loop-facts:31-32、未決事項 1）。2026-09-28 時点で `shin1ohno/ai-memory` は存在しない（`git ls-remote`）。

survey `cross-refs.summary` は、ADR 0002・0003 が第 3 リポを却下済みで新リポと衝突すると指摘した（「ADR 0002・
0003 との関係」節）。選択を左右するセキュリティ上の事実は「セキュリティ上の前提」節にまとめた。

## Decision

### 1. サーバ側のアプリケーションコードを `shin1ohno/ai-memory` へ移す

移すのは memory-mcp、memory-keeper、auth-proxy、ES 索引定義である（handoff §1）。クライアント側の置き場所は
未決事項 4、systemd unit・env と health のスクリプト・`requirements*.txt` の置き場所とサイト値の持ち方は未決事項 3
で扱う。

### 2. setup は取得・配置・設定を持つ

配置の recipe（`cookbooks/lxc-es-memory`、`cookbooks/memory-mirror`、claude-code cookbook の hook 配布）と entry
（`pve/lxc-es-memory.rb`）は setup に残る。recipe は `require_external_auth`・`systemd_unit`・`node[:setup]`・
`ssh-keys/files/aws-config.json` という setup の枠組みに依存し、新リポ単体では動かない（survey
`deploy-recipe.couplings`・`cross-refs.couplings` helper-call）。取得の方式は未決事項 1・2 で、どのサイト値を setup が
注入するかは未決事項 3 と結合 7 で決める。

### 3. CT 119 に新しい資格情報を置かない

ai-memory は public なので、CT 119 は setup と同じ匿名 HTTPS で取得できる。CT 119 のディスク上にあるのは
`/root/.ssh/authorized_keys`、https の setup remote、`pve-bootstrap-ssm` プロファイルだけで、GitHub の資格情報は
無い（survey `precedents.stream_specific` §5、`auto-mitamae-target/default.rb:50`）。ただしこのプロファイルは
SSM から account-wide な GitHub 鍵を読める（S1）。本 ADR はこの経路を広げも狭めもしない。

### 4. IAM 信頼境界は動かさない

IAM・KMS・SSM 書き込みの定義は home-monitor に残り、ai-memory は AWS の principal を持たない（「ADR 0002・0003
との関係」節）。

## セキュリティ上の前提（未決事項 1 と §7 の選び方を変える）

- **S1 既存の露出**: fleet 各デバイスの GitHub user key（アカウント全体への push 権）は home-monitor が登録し
  （`ssh-devices.tf:117-120`）、秘密鍵は SSM `/ssh-keys/devices/*` にあって、fleet 共有の `pve-bootstrap-ssm` が
  読める（`pve-bootstrap-iam.tf:107-127`）。setup main には ruleset も branch protection も無い（2026-09-28 の読み取り
  probe: `gh api repos/shin1ohno/setup/rulesets` が 0 件、`branches/main/protection` が 404「Branch not
  protected」）。fleet のどの LXC を取られても setup main へ直接 push でき、それが fleet 全体への root での deploy に
  なる。ai-memory を既定設定のまま作ると、同じ状態を 2 つ目のリポにも作る。setup 側の露出は本 ADR の範囲外で、
  setup の `TODO.md` 先頭に記録済みで（2026-09-28）、直すときは adversarial review（handoff §10）を通す
- **S2 (b) 浮動 ref の帰結**: ai-memory main への push（S1 の鍵、factory の Contents 書き込み PAT、loop-facts:24）が
  setup の commit も canary も経ずに、最長約 72 分で CT 119 へ root で載る（「反映経路の変化」）
- **S3 (a) pin が統制として効く条件**: 次のどれかが欠けると (b) に近づく。
  (i) SHA で pin する。tag を pin して git checkout（2a）で取ると、tag を動かせる者が setup の commit なしで
  reconcile 時に CT 119 を変えうる [推測: 取得の実装次第]。tag を使うなら 2(b) の sha256 か、cookbook 側での
  tag→SHA 照合を必須にする。先例の roon-mcp は tag pin である（`lxc-roon-mcp/default.rb:30,146`、`#v0.5.7`）。
  (ii) bump PR の差分は 40 文字の SHA だけで、ai-memory 側のコード差分がレビュー面に出ない。PR 本文に
  `compare/<old>...<new>` を必須にする。
  (iii) setup には人間の merge を経ない経路が既にある。self-heal-resolve は class A/B を merge まで自律で行う
  （`claude-code/files/skills/self-heal-resolve/SKILL.md:7,60-61`）。ai-memory の pin と MANIFEST をその対象から
  外す（class D 扱い）。
  (iv) L3・L6 で agent が bump PR を書く場合は human merge を必須にする
- **S4 ruleset（推奨する前提条件）**: ai-memory の main に ruleset（直接 push 禁止・required checks・bypass なし）を、
  初回 import の後、CT 119 が取得を始める前、factory のトークンを入れる前に置く。ruleset の変更には
  Administration 権限が要り、user key（git 操作のみ）も Contents・PR の PAT もそれを持たない [推測: GitHub の
  権限モデルからの推論、未実測]。S1 の鍵による直接 push はこれで止まる
- **S5 個人データ**: unit の `ALLOWED_SUBS` に個人メール 2 件（`memory-v2-proxy.service:32`、値は伏せる）、テストに
  メール 1 件、`eval/golden_set.jsonl:1-3` に身体属性がある（survey `runtime-code.risks`）。setup で既に公開済みだが、
  `eval/` や履歴を持ち込むと 2 つ目の public リポに再掲される（未決事項 3・5・6）
- **S6 資格情報**: 計画全体で新設・変更されるものは Consequences「新規・権限変更される資格情報」に並べた

## 未決事項（Open questions）

次の 10 項目は未決で、本 ADR は選択肢を並べ、推奨があるものは理由を添える（handoff §5）。

| # | 問い | 選択肢 | 判断材料 |
|---|---|---|---|
| 1 | 版の取得 | (a) SHA を pin (a') tag を pin（roon-mcp 型） (b) 浮動 ref（main）を converge ごとに取得（edge-agent C 型・git_clone E 型） | 「反映経路の変化」、S2・S3。推奨は (a)。調査と handoff §5-1 の推奨は「tag か SHA の pin（roon-mcp 型）」で、SHA に絞るのは本 ADR の S3(i) の結論。S2 の経路を閉じ、起点が setup の commit 1 つに保たれ、pin した SHA が setup の履歴に残る。代償は 1 変更あたり PR 2 本と S3 の運用条件 |
| 2 | 1 で (a)・(a') の場合の配布形式 | (a) pin した ref の git checkout + ファイル配置 (b) release tarball + sha256（herdr・node_exporter 型） (c) wheel の pip install（ADR 0010「次の段」4）。wheel の取得元は CT 119 上でのビルド / GitHub release asset / PyPI | keeper は prompts を `__file__` 相対で読む（`reconcile.py:40`、`consolidate.py:58`）ので、flat py-modules の wheel では配れない。memory-mcp と proxy は venv を共有する。(a') と組むなら (b) の sha256 か tag→SHA 照合が要る（S3）。PyPI なら公開トークンが新たに要る。結合 1・5 と連動する |
| 3 | unit 8 本・`generate_env_v2.sh`・`memory-keeper-health.sh`・`requirements*.txt` の置き場と、サイト値の持ち方 | (a) ai-memory（アプリの契約。SSM パス、AWS プロファイル、ES の接続先、OIDC の issuer・audience・subject、配置パスは setup が env で注入する） (b) setup（サイト設定。値は今と同じく unit とスクリプトに直書き） | 今のサイト値はアプリ側のファイルに直書き（`generate_env_v2.sh:30,34`、`memory-v2-proxy.service:11-12,27,32,35`）。(a) なら既存テストが無修正で動く（結合 3）が、注入の仕組みが要り、`ALLOWED_SUBS`（S5）も注入側へ移る。(b) ならリポ横断の drift 検査が要る。`requirements*.txt` はどちらでもコードと同じリポに置くことを推奨する。setup に残すと新しい依存を要する版が依存より先に届き、crash-loop しうる（ADR 0010:43-46 の型）。health スクリプトの metric 名は lxc-monitoring の alert との契約になる |
| 4 | クライアント側（hook・テスト・`register-memory-mirror`）の置き場 | (a) ai-memory へ移す (b) claude-code cookbook に残す | hook は個人 store と memory-work の両方で使われる（survey `client-side.open_questions`）。結合 6・8 |
| 5 | 履歴 | fresh（1 commit）/ filter-repo（13 spec で 35、移すコードに絞ると 29）/ subtree split（30）/ 前身込み（98）。件名の `(#N)` を `shin1ohno/setup#N` に書き換えるか。Co-Authored-By trailer（11 commit に計 21 行。handoff と survey の「25 本」は 6218cf1 の本文にある説明文 4 行も数えている）を除くか | 35 本すべてが squash merge で `(#N)` と gpgsig を持ち、20 本は対象外のパスにも触れる（survey `history.summary`。29・12 は d6d70f2 で再計測）。fresh 以外は handoff §10「main に push しない」とぶつかる。空のリポへ履歴を入れるには、初回だけ main への直接 push を例外として認めるか、初期 commit の上へ rebase して rebase merge で取り込む [推測: GitHub は共通の祖先を持たないブランチ間で PR を作れない]。squash merge では履歴が消える。パスを絞ると tree が変わるので、元の gpgsig はどの方式でも無効になる。git-filter-repo は未導入（PyPI・apt・mise で入手可）。履歴には S5 の個人データも入る |
| 6 | legacy の扱い | `migrate/`、壊れた `eval/eval_reconcile.py`、`eval/` の個人データ（S5）、追跡された `.pyc`、消費者の無い `register-memory-keeper`（secret を argv に載せる）、v1 の retire execute、孤立した Hydra client `memory-keeper` と SSM `/memory/keeper-client-*` を捨てるか持ち込むか | 最後の 2 つの削除はユーザーの承認が要る（handoff §10）。消す場合は、先に `ALLOWED_CLIENT_IDS`（`memory-v2-proxy.service:35`）と `CLIENT_POLICY`（`memory-mcp-v2.service:34`）から同じ PR で外し、その後に Hydra と SSM を消す |
| 7 | work overlay の memory-work を範囲に入れるか | 入れる / 入れない | 取り込み方が未確認（Consequences「work overlay」）。入れないを選んでも、setup からファイルを消す前提条件（同節）は残る |
| 8 | ADR 0010「次の段」1〜2 の時期 | 分割前に setup で行う / 分割後に ai-memory で行う | `server.py` は import 時に ES へ接続する（ADR 0010:43-46）。次の段 3（版別ディレクトリ）はロールバックの形を変える（「切替とロールバック」） |
| 9 | 文書の置き場 | ADR 0007・0008・0010 を移すか残すか。`knowledge-persistence.md:17-25` をポインタだけにするか | 同節は常時ロードの doctrine で、hook のパスを名指しする（survey `client-side.couplings` docs-link） |
| 10 | 開発機への自動 clone | `roles/manage/files/repositories.json`（14 件）に足す / 足さない | 足さないと開発機の `~/ManagedProjects` に clone されない（survey `precedents.couplings` docs-link） |

## ADR 0002・0003 との関係

ADR 0002 は「**コード (Ruby helper / Terraform module) を含む第 3 リポは却下**」とした（0002:16）。対象は
Identity & Access（host registry、IAM 定義、Tailscale ACL、SSH 鍵 SSM 定義）を `home-identity` へ切り出す案で
（0002:8）、理由は push 権限保有者が「IAM principal 新規作成 / credential SSM 投入 / cookbook 経由 LXC 展開 を
1 PR で実行可能」になる privilege aggregation だった（0002:34-38）。ADR 0003 は「**`home-monitor` と `setup` の
リポジトリ境界 = AWS IAM 信頼境界として扱う**」とし（0003:11）、第 3 リポを「自動的に却下」したうえで（0003:30）、
不変条件を 4 つ置いた（0003:40-43）。

| 観点 | `home-identity`（ADR 0002 が却下） | ai-memory |
|---|---|---|
| 中身 | IAM principal 定義、Tailscale ACL、SSH 鍵の SSM 定義、host registry、Ruby helper、Terraform module | Python アプリ、ES 索引 JSON、（未決）unit とスクリプト。`aws iam`・`aws kms`・`put-parameter` の `git grep` は `cookbooks/lxc-es-memory` で 0 件（8d3b48b） |
| 境界の中の位置 | home-monitor と setup を統合する層 | setup の下流にあるアプリ 1 つ。roon-rs・weave と同じ位置（survey `precedents.stream_specific` §1 A・B） |
| merge で起きる credential 発行 | IAM principal・SSM secret・LXC 展開が 1 PR で起きる | 起きない。SSM に書くのは operator が PutParameter を持つ profile で手で実行するスクリプト（`bin/register-memory-{mirror,keeper}`、`bin/issue-apm-api-keys.sh:32-37,77-86`）だけで、`register-memory-mirror` は Hydra client も作る（`POST /admin/clients` は `:127`、SSM への書き込みは `:142-147`）。merge を契機に走るものは無い |
| CT 119 の AWS 権限 | — | `pve-bootstrap-ssm`（`/ssh-keys/devices/*`・`/monitoring/{elastic,apm}/*`・`/hydra/*`・`/memory/*` の読み取り、home-monitor `pve-bootstrap-iam.tf:107-227`）のまま。`/ssh-keys/devices/*` から account-wide な GitHub 鍵に届く経路は既にあり（S1）、切り出しはこれを広げも狭めもしない |

IAM 信頼境界は動かない。cookbook は setup に残り AWS 側を変えないので、ADR 0003 の不変条件 1〜3（cookbook は
`aws iam`・`aws kms`・`ssm put-parameter` を呼ばない、Terraform state に cookbook の identity が届かない、
`pve-bootstrap-ssm` に PutParameter を足さない）は保たれ、4（`setup_ci_ssm_reader`）にも触れない。移すテスト 4 本は
AWS の資格情報を持たない `syntax-check` job で走る（`test-setup.yml:522`。OIDC は `ssm-validation` job だけ、`:733-744`）。

ADR 0002 の懸念が ai-memory に当てはまるには、次のどれかが成り立つ必要がある。

1. ai-memory が IAM・KMS・SSM 書き込みの定義を持つか、merge を契機にそれを実行する。現状はどちらも無い
2. ai-memory への push だけで fleet ホストに root でコードが載る。(a) SHA pin なら単独では起きない（setup の
   bump commit が要る）が、bump の統制は S3 の条件にかかる。(a') tag pin は tag を動かせる者に経路を開きうる。
   (b) なら reconcile で CT 119 に載り、ADR 0002 が setup について書いた「cookbook write 権限 (LXC RCE 等価)」
   （0002:23）を 2 つ目のリポへ広げる。push できる主体は S1 の user key と factory の Contents 書き込み PAT
   （loop-facts:24）で、同じ権限は setup について既に fleet 全体へ広がっている（S1）
3. Hydra client や SSM secret の宣言を ai-memory が持つ。現状 client はどのリポにも宣言されていない（survey
   `client-side.summary` 4）。未決事項 4 で `register-memory-mirror` を移すと credential を作る手順は ai-memory に
   入るが、実行は PutParameter を持つ operator の手作業のままである

ADR 0002 のセキュリティ上の懸念（IAM の privilege aggregation）は ai-memory に当てはまらない。deploy 権限の広がりは
主に未決事項 1 で決まり、(a) でも S3 の条件と S4 の ruleset が要るので、未決事項 1 はセキュリティ上の判断でもある。
運用面の懸念（release ordering、multi-repo の認知負荷、fork 化、3 つ目の clone。0002:22-24,40-44）は一部が当てはまる。

ADR 0002 と 0003 の決定は変更しない。ただし `CLAUDE.md:163`（「廃案: …第 3 リポ抽出 (privilege aggregation
anti-pattern)」）と ADR 0003:30 は無条件に読め、後続のセッションや auto-mode の classifier はルール文をそのまま
引く（`.claude/rules/infrastructure.md`「Auto-Mode Classifier Boundary」末尾）。実装時に `CLAUDE.md:163` へ「アプリ
だけのリポは ADR 0013 で対象外」と注記し、ADR 0002・0003 の Status 行に ADR 0013 への参照を足す。

## ループ選択（handoff §7）との関係

§7 の比較と推奨は `loop-options.md` にあり、本 ADR は選ばない。L ごとに本 ADR の記述が変わる箇所は次のとおり。

- L1: ai-memory に factory の PAT と secret が入る（「新規・権限変更される資格情報」）。S2 の push 主体に PAT が加わり、
  S4 の ruleset が前提になる。(a) なら PAT の書き込みは CT 119 に届かない
- L2: dispatch トークンをリポごとに分ける（handoff §10 の review 対象）。本 ADR の結論は L1 と同じ
- L3: 「pin を上げる」がタスクになり、書き先は setup なので L6 が要る（loop-options §2 L3 行）。agent が書く bump
  PR には S3 (iv) の human merge を課す
- L4: 信頼されたジョブが setup@SHA を読むだけで、本 ADR への影響は無い
- L5: 自動化するなら、LAN に入れる runner が要る。確認を mirror の `--check`（既存の `memory-mirror` client、ingest と forget）で行えば新しい資格情報は要らない。recall と remember まで往復させるなら、CLIENT_POLICY の文法が ingest と forget しか許さないため identity.py の認可モデルを変え、全 memory を読める machine client を 1 つ増やすことになり、client id も 3 リポ契約に 1 つ増える（loop-options.md の安全 4）。
  runner を CT 119 に置く形は Decision 3 と両立しない（loop-options は pro-dev に置く案）
- L6: setup の Contents 書き込み PAT は ADR 0002:23 の「cookbook write 権限 (LXC RCE 等価)」そのもので、setup main は
  無保護なので（S1）ADR 0002 の懸念に直接当たる。setup の ruleset と ADR 0003 不変条件 1 の lint 検査（未実装、
  loop-options §3 L6）が先に要る

## Consequences

### 分割で壊れる 8 つの結合と解き方の選択肢

file:line は setup d6d70f2 のもの。d6d70f2 から 8d3b48b までのリポ全体の差分は `.claude/rules/shell.md` と
`claude-code/files/rules/ask-user-question.md` の 2 本だけで、本 ADR が引くファイルは含まない。

| # | 結合 | 壊れ方 | 解き方の選択肢 |
|---|---|---|---|
| 1 | `lxc-es-memory/default.rb:213-216`・`417-419` が MANIFEST を compile 時に `File.read` する | converge 時の git fetch では、新規ホストで compile が失敗し、既存ホストには 1 つ前の版の一覧が配られる | (a) 取得を前段のプロセスへ移す。ADR 0012 の bootstrap に似るが、0012 は Proposed で、bootstrap は対話用の `bin/converge` にしか無く、fleet の runner は `./bin/mitamae local "$role"` を直接呼ぶ（`mitamae-runner.sh:308`）。hosts.json の全 18 ホストの runner 変更か ADR 0012 の改訂が要り、ADR 0009 の状態管理にも触れる (b) MANIFEST を compile 時に読まず、取得物を 1 つの `execute` で丸ごと置く (c) wheel を pip install する（未決事項 2c） (d) pin を上げるときに MANIFEST だけを setup へ vendoring する（survey `precedents.stream_specific` §1 I 型）。配布物そのものの vendoring は handoff §9「setup に runtime コードが残っておらず」と矛盾する |
| 2 | `bin/lint-cookbooks` の check 15 | `sensitive true` の無い placement のうち、source が `files/`・`templates/` 以外のものは secret 扱いで FAIL になる（`lint-cookbooks:94-108,1107,1191`） | (a) 宣言した checkout root を REPO_SOURCE に加える（secret 検査が信頼する範囲を広げる） (b) placement ごとに理由付きで `SENSITIVE_EXEMPT` に足す (c) コードの配置を `execute` にする（check 15 の対象外。`.claude/rules/ruby.md`「Secret-bearing placements」） (d) `sensitive true` を付ける（コードの差分がログに出なくなる） |
| 3 | `test_client_policy.py` が `../systemd/*.service` を読み（`:48,72,563`）、`test_merge_rules.py` が `../memory-mcp/identity` を import する | unit とコードが別リポになるとテストが入力を失う | (a) `memory-mcp/`・`memory-keeper/`・`systemd/` を ai-memory で兄弟のまま置く（4 本が無修正で動く、survey `runtime-code.summary` 2） (b) unit を setup に残し、setup の CI が pin した ai-memory を取得してテストを回す (c) テストが読む値を fixture に切り出し、setup 側で unit との一致を別に検査する |
| 4 | `bin/check-memory-v2-manifest:26` の BASE、`test-setup.yml:592-663` の 6 step、mirror hook の step（`:675-683`）がパスを直書きする | ファイルが消えると CI が ENOENT で落ち、ADR 0010 の「配布物そのものを検証する」保証がどちらのリポでも成り立たなくなる | (a) 検査を ai-memory の CI へ移し、setup には pin した ref の取得と配布契約の検査を置く (b) BASE を引数にし、setup の CI が pin した checkout に対して走らせる (c) (a) と (b) の両方 |
| 5 | runner が毎サイクル `/root/setup` で `git reset --hard` と `git clean -fdq` を実行する（`mitamae-runner.sh:190-191`） | `/root/setup` の下に置いた .git を持たない展開物（tarball・sdist）は毎サイクル消える。入れ子の git checkout は単一の `-f` では残るが（git 2.47.3 の scratch で再現。CT 119 の git 版は未測定 [推測: 同じ挙動]）、setup の untracked として残り、`-f` を 2 つ重ねる（`-ff`）と消える（`-x` だけでは消えない） | (a) 取得物を `/root/setup` の外に置く。`/opt/es-memory/app` と `/opt/es-memory/es-indices` は retire execute が毎 converge `rm -rf` するので使わない（`lxc-es-memory/default.rb:144-151`） (b) tarball か wheel を `/root/setup` の外へ展開・install する |
| 6 | クライアントとサーバの契約定数が分かれて置かれる。サーバ側は `policy_denied:`・45000 が `identity.py:207,222`、audience・client_id が unit（`memory-v2-proxy.service:27,35`、`memory-mcp-v2.service:34`）、TTL 3600 が Hydra（setup の `lxc-hydra/files/hydra.yml:59`）。hook 側は `mirror-file-memory.rb:114,130,219,231-238,860` | サーバ側と hook を 1 PR で変えられなくなる。サーバが上限を下げると、hook は送ってから拒否される。TTL は hook と setup の lxc-hydra の間で閉じるので、分割後も 1 PR で変えられる | (a) hook も ai-memory に置き、同じ PR で変える（未決事項 4a） (b) hook を setup に残し、setup の CI で pin した `identity.py`・unit と hook の定数を照合する（TTL は setup 内で照合する） |
| 7 | ai-memory・setup・home-monitor の 3 リポにまたがる契約（次の表） | 片側だけの変更が、connector の 502/404、alert の無効化、外形監視の脱落、SLM バックアップからの脱落を黙って起こす | (a) 契約の値を ai-memory の文書に interface として宣言し、setup と home-monitor が参照する (b) サイト値を setup が持ち、unit へ env で注入する（未決事項 3a と組む） (c) pin を上げる PR で setup の CI が値を照合する（ADR 0004 の jq sanity check と同じ形） |
| 8 | hook の settings.json 登録（`claude-code/files/settings.json:130,146`）と本体の配置（`claude-code/default.rb:241`） | 分かれると、登録だけあって本体が無いホストができる。`hooks` キーは shallow merge なので、登録を別の cookbook に分けられない（survey `client-side.couplings` path-contract） | 制約: 登録と本体は同じ cookbook に置く。(a) claude-code cookbook が pin した ai-memory から hook を取得し、今と同じく全ホストに配る (b) hook を claude-code cookbook に残す（未決事項 4b） (c) memory-mirror cookbook が mirror 対象ホストにだけ置く（claude-code の merge 方式の変更が前提） |

3 リポにまたがる契約（結合 7）は次のとおりである。「アプリ側」は今の `cookbooks/lxc-es-memory/files/` 配下の
定義箇所で、どこまで ai-memory へ移るかは未決事項 3 で決まる。

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
全体の上限は約 2 時間）。ai-memory の commit はこの起点を動かさない（survey `deploy-recipe.summary` 4）。

| | (a) SHA pin・(a') tag pin | (b) 浮動 ref を converge ごとに取得 |
|---|---|---|
| ai-memory への merge | 何も deploy しない（(a') は tag の扱い次第、S3） | CT 119 の次の reconcile（最長約 72 分後）で載る |
| setup への merge | pin を上げる commit が即時の converge を起こす | ai-memory の版は変わらない |
| canary（pro-dev） | gate は動くが、pro-dev は lxc-es-memory を include しない（`hosts.json:10,18`、`pve/lxc-pro-dev.rb:187` は memory-mirror だけ）ので server 側の変更は検証しない。client 側を未決事項 4(a) で移す場合だけ pro-dev で一部検証される | 通らない |
| SHA 単位の apply 状態（ADR 0009） | setup の SHA として残る | 残らない |
| 稼働中の版の観測 | apply-state は setup の SHA で、converge が途中で失敗すると配置物と食い違う（`mitamae-runner.sh:112-119`）。配置先に ai-memory の SHA を書いた印を置き、それを正とする（handoff §9） | setup からは見えない。同じ印が要る |
| 1 変更あたりの PR | ai-memory と setup の 2 本 | ai-memory の 1 本 |

(b) の先例は edge-agent（C 型、`edge-agent/common.rb:19,36-39` の `@latest`）と git_clone + pull（E 型）である。
weave（B 型、`lxc-weave/default.rb:37-38`）も main を追うが、image tag `:main` が自分自身と一致して再ビルドしない
ので（`functions/default.rb:720-721`）、compose ファイルが変わるまで届かない（survey `precedents.stream_specific`
§1 B・C・E）。浮動 ref でも取得の仕組み次第で更新が永久に届かない。canary が CT 119 を検証しないので、どちらを
選んでも切替の条件は CT 119 上の機能 probe（handoff §9 の 4 点目。L5 か人間の手順）である。

取得の先例はどれも GitHub の REST API（未認証は IP あたり 60 回/時）を経由せず、固定 URL の `releases/download/`
と sha256（herdr・node_exporter）か `git ls-remote`（`drift-checker.sh:5`）を使う（survey `precedents.stream_specific` §1 D）。

### 切替とロールバック

今の配置は MANIFEST の各ファイルを `remote_file` で足すだけで、MANIFEST から消えたファイルを消さない
（`lxc-es-memory/default.rb:213-225,417-424`）。推奨する手順は次のとおりで、振る舞いの変更は切替と別の PR にする。

1. ai-memory を作り、初回 import、CI、S4 の ruleset を整える
2. setup の配置元を pin した ai-memory へ切り替える PR を、setup 同梱と内容が同一の版で出す（CT 119 に届く
   ファイルの差分が 0 であることを確かめられる）。その後 CT 119 の機能 probe（handoff §9 の 4 点）を通す
3. 「work overlay」節の前提を満たしてから、setup の複製を消す PR を出す

切替 PR を revert すると、次の converge で setup 同梱のファイルが上書きされるが、ai-memory の版で増えたファイルと
取得物は残る [推測: 取得の実装次第]。版別ディレクトリへの切替（ADR 0010 次の段 3、`0010:74-75`）を先に入れると、
ロールバックは参照先の付け替えで済む。入れる時期は未決事項 8 と同じ回で聞くことを推奨する。

### 新規・権限変更される資格情報

| 資格情報 | 変化 | 生じる条件 | 根拠 |
|---|---|---|---|
| CT 119 | なし | public のまま（Decision 3） | handoff §2 |
| ai-memory の `GH_AW_CI_TRIGGER_TOKEN`（fine-grained PAT、Contents・PR の RW） | 新規 | factory を ai-memory に入れる（L1 とその上の案すべて） | loop-facts:24 |
| ai-memory の `GH_DISPATCH_TOKEN`（issues:write） | 新規 | 同上 | loop-facts:25 |
| `CLAUDE_CODE_OAUTH_TOKEN`・`LINEAR_API_KEY` | ai-memory の secret に複製 | 同上 | loop-facts:23,26 |
| 中継の PAT（SSM `/agent-pilot/linear-forwarder/github-token`、sandbox 1 リポの Actions RW） | 対象の付け替えか 2 本目 | L1（handoff §7 L1） | loop-facts:17,27 |
| dispatch トークンのリポ別分割 | 権限範囲の変更 | L2 | handoff §10 |
| PyPI の公開トークン | 新規 | 未決事項 2(c) で PyPI から配る場合 | — |
| probe 用 Hydra client（recall・remember を往復できる） | 新規 | L5 を自動化し、recall と remember まで往復させる場合（identity.py の認可モデル変更を伴う。mirror の `--check` で代えるなら不要） | loop-options §2 L5 行 |

どの行も実装前に adversarial review を通し（handoff §10）、home-monitor の apply はユーザーの許可を得てから行う。

### CI の変化

- setup から消えるもの: `syntax-check` job の memory 系 6 step（`test-setup.yml:592-663`）。クライアント側を移す
  場合は mirror hook の step（`:675-683`）も消える
- ai-memory に作るもの: 4 テストスイート（17・45・111 + skip 1・29 件、survey `runtime-code.summary` 2）、配布物の
  import 検査（ADR 0010 Decision 2）、proxy の import テスト（handoff §9）。S4 の ruleset はこれらを required checks にする
- setup に残るもの: `bin/lint-cookbooks`・`bin/audit-cookbook-reachability`・`ruby -c`（survey `cross-refs.couplings`
  ci-job）。(a)・(a') なら pin した ref の実在と配布契約を確かめる検査も要る（survey `precedents.couplings` ci-job）

### work overlay（未確認）

work overlay（private）は memory-work（sh1-cloud）で同じサーバコードを動かし（`memory-mcp/server.py:35-37`）、
claude-code cookbook が配る hook を server-name 形式の config で使う（survey `client-side.couplings` deploy-trigger）。
overlay の clone は pro-dev にも mini にも無く、work Mac には ssh で届かず、sh1-cloud は pro-dev から名前解決できない
（2026-09-28、`ssh sh1-cloud` が Could not resolve hostname）。overlay がサーバコードを setup のパスから読むなら、
setup からファイルを消すと memory-work が壊れる [推測]（survey `cross-refs.couplings` file-read）。hook の変更も波及する。

前提条件: overlay を clone できるホストで取り込み方を確認するまで（handoff §8-2）、setup の対象ファイルを消す PR は
出さず、長引くなら互換用の複製を setup に残す。未決事項 7 で「入れない」を選んでも、この前提は残る。

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

## References

- ADR 0001（モノレポ却下）、0002（第 3 リポ却下）、0003（IAM 信頼境界 = リポ境界）: 決定は変更しない（注記の追加は
  「ADR 0002・0003 との関係」末尾）。ADR 0004（host registry の SSM 配送。リポ横断契約の型付けの先例）
- ADR 0009（SHA 単位の apply 状態）、0010（memory-v2 の配布単位と「次の段」）、0012（compile と converge の順序、Proposed）
- 調査: `~/.claude/plans/ai-memory-extraction-2026-09-27/survey.json`（setup d6d70f2、home-monitor 00e3e84、
  2026-09-27。本 ADR が引く home-monitor のファイルは 9425148 まで差分なし）、同ディレクトリの `handoff-prompt.md`・
  `loop-facts-2026-09-28.md`・`loop-options.md`（§7 の比較）
