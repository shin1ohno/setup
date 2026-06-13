# Setup リポジトリ全面リファクタリング計画（2026-06）

Status: **Phase 0-5 実質完遂（2026-06-13）**。Phase 0/1/2-0/2-1/3 マージ済み、G1 クローズ(実態空)、
Phase 4 抽出 3 件(weave/pro-router/consent)マージ + 実機 canary 検証済み(fleet 19/19 success)、
case-B 4-3b(lxc-consent → pve-bootstrap-ssm、home-monitor PR #95 で IAM grant + live decrypt 検証済み)完了、
Phase 4-4/5 docs マージ済み。**残る外部依存のみ**: (a) #479 local-mcp = Air(Mac)が 2日 offline で apply 待ち、
(b) lxc-hydra case-B = /memory/* grant が別途必要(bare 据え置き)、(c) G2 multi-step cookbook(apm/kibana/es 等)は
helper 非適合で対象外。詳細は `docs/refactoring/result.md`。
本ファイルが進捗台帳の正本。各 PR のマージ時にチェックボックスを更新し、完了 Phase はマージコミットへのリンクを残すこと。

## 決定事項ログ

| # | 決定 | 日付 |
|---|---|---|
| D1 | 休眠 3 cookbook（memory-server / oh-my-zsh / typewritten）も削除する（git 履歴から復元可能） | 2026-06-13 |
| D2 | Ruby は 3.3 一本化。ruby32 を削除（roles/programming から include を外す） | 2026-06-13 |
| D3 | python / rust の mise 統一は Phase 3 で**調査のみ**。実行は調査結果を見てユーザーが判断 | 2026-06-13 |
| D4 | 本プランは docs/refactoring/plan.md にコミットし進捗台帳を兼ねる | 2026-06-13 |
| D5 | SSM を読む LXC fleet cookbook を「明示 `--profile`（namespace 別の正しい profile）」パターンに統一する（案 B）。ただし darwin/bare-metal の bare/default-profile（mcp, codex-cli）は維持。詳細は下記「案 B（SSM profile 統一）スコープ」 | 2026-06-13 |

## 背景: 調査で判明した無駄（2026-06-13 調査）

規模: 145 cookbook / 約 14,800 行（recipe Ruby）。

### Dead cookbook（削除対象、Phase 1）

| cookbook | 最終更新 | 根拠 |
|---|---|---|
| `ruby` | 2023-03 | default.rb が**空ファイル** |
| `openssl` | 2023-03 | include 参照ゼロ。他所の "openssl" は全て apt/brew パッケージ名 |
| `autoconf` | 2026-01 | neovim は apt パッケージ `autoconf` を直接使用。cookbook 不使用 |
| `disable-ipv6` | 2026-01 | 参照ゼロ |
| `im-select` | 2026-01 | dot-config-nvim が brew tap で直接インストール。cookbook 不使用 |
| `memory-server` | 2026-05 | 休眠（pve/lxc-memory.rb のコメントで「openmemory-mcp 修復後に戻す」）→ D1 で削除決定 |
| `oh-my-zsh` | 2025-05 | 休眠（dot-zsh のコメントで「意図的残置」）→ D1 で削除決定 |
| `typewritten` | 2026-04 | 休眠（同上、starship に置換済み）→ D1 で削除決定 |

到達性の判定方法: darwin.rb / linux.rb / test-cookbook.rb / pve/*.rb をルートに
`include_cookbook` / `include_role` / `include_recipe "cookbooks/..."` を推移的に辿る。
ripgrep 一発の近似: `rg -o 'include_cookbook[ (]+"([^"]+)"' -r '$1' --no-filename | sort -u`
を `ls cookbooks` と comm で突き合わせ。

### 重複クラスタ（Phase 2 / 3 の対象）

| クラスタ | 対象 | 削減概算 | 難易度 |
|---|---|---|---|
| systemd unit 4 ステップ手書き（staging → sudo install → daemon-reload+enable → restart） | 24 cookbook（node-exporter, s3-backup, unbound-watchdog, lxc-hydra 等） | ~700 行 | 低 |
| docker-compose デプロイ手書き（`compose_service` DSL が既存なのに未適用） | 10 cookbook（lxc-monitoring, lxc-praeco, lxc-elasticsearch, lxc-kibana, lxc-apm-server, lxc-hydra, claude-code, local-mcp, mcp-probe 等） | ~210 行 | 低 |
| `.env 生成 + require_external_auth(SSM) + remote_file + temp 削除` 定型 | 9 cookbook（lxc-cognee, lxc-memory, lxc-monitoring, lxc-praeco, lxc-elasticsearch, lxc-kibana, lxc-hydra, lxc-apm-server, elastic-agent） | ~120 行 | 中 |
| curl+tar 手書きインストール → `mise_tool` 化候補 | gcloud-cli, neovim, speedtest-cli, zk 等（要 5-check 検証） | ~330 行 | 低〜中 |
| dotfile 系 directory+remote_file 反復 | 6 cookbook | ~30 行 | 低（優先度低、Phase 5 で要否判断） |

`compose_service` 採用済みの参照実装: lxc-cognee / lxc-memory / lxc-roon-mcp。
platform 分岐（88 cookbook）は調査の結果ほぼ正当 — 統一対象外。

### 構造の偏り（Phase 4 の対象）

- `pve/lxc-*.rb` の大半は 14-60 行の薄いエントリだが、3 つだけインラインロジックを抱える:
  `lxc-weave.rb`（284 行）、`lxc-pro-router.rb`（224 行）、`lxc-consent.rb`（181 行）
- `ruby32`（3.2.1）と `ruby33`（3.3.0）が roles/programming で両方 include されている → D2

### 残骸（Phase 1 の対象）

- `docs/adr/0005-impl/` — 完了済み ES 移行のフェーズ手順書 10 ファイル + `.patch` 2 ファイル
- `docs/HANDOFF.md` — 鮮度監査が必要
- TODO.md の `dns-prefer-ipv4` は RTX 上流修正待ちのため本計画スコープ外（トラッキングのみ）

### lint 観点の現状（Phase 0 で機械化する検査の事前調査結果）

- トップレベル `if File.exist?`: 真の hit は `roles/manage/default.rb:14` のみ
  （ユーザー管理の local override 読み込みで、リソースの副作用に依存しないため**許容 → allowlist**。
  cookbooks/claude-code/files/ 配下はドキュメントなので検査対象外とする）
- Integer `owner`/`group`: 違反 0 件（claude-code/files/rules/*.md の hit はドキュメント例）
- `check_command` の profile（**2026-06-13 再調査で当初の見立てを訂正**。下記「案 B（SSM profile 統一）スコープ」が正）:
  - 当初 plan は「`--profile` の有無」を違反基準にしたが**誤り**。正しい規約（`~/.claude/rules/ruby.md`
    "Auth-check gate must match the cookbook's actual invocation profile"）は
    「check_command の profile が同一ブロックの実呼び出しと一致するか（mismatch 検出）」
  - bare↔bare（check も実呼び出しも profile なし）は整合が取れており**規約違反ではない**。
    `pve/lxc-consent.rb:131` と `cookbooks/lxc-hydra/default.rb:127` がこれに該当
  - 誤検知に注意: 継続行（`" \` 改行 `"--profile ..."`）や変数渡し（`orchestrator_ssm_check` 等）、
    さらに `instructions:` フィールドが "aws configure --profile <name>" を含むため、
    lint は **check_command の値だけを抽出**して判定すること（単純 grep / `-A4` window は不可。
    精密抽出 Ruby は本セッションで作成済み: `/tmp/.../classify_v2.rb` を参考実装に）
- notify 駆動 `docker compose up -d` の `--force-recreate` 欠落: lint 実装時に block 単位で再確認

### 案 B（SSM profile 統一）スコープ（D5、2026-06-13 精密調査）

check_command 値の精密抽出（継続行・変数解決・instructions 除外）で全 recipe を分類した結果:

- **BARE（profile なし）4 件**: `cookbooks/lxc-hydra/default.rb:127`, `cookbooks/mcp/default.rb:55`,
  `cookbooks/memory-server/default.rb:77`, `pve/lxc-consent.rb:131`
- **EXPLICIT（`--profile` あり）21 件**: elastic-agent(×3), lxc-cognee, lxc-memory, lxc-monitoring(×2),
  lxc-praeco, lxc-kibana(×2), lxc-elasticsearch(×2), lxc-apm-server, lxc-roon-mcp, mcp-probe,
  local-mcp, edge-agent, auto-mitamae-{target,orchestrator}, ssh-keys, pve/lxc-weave 等
- **STS（sts get-caller-identity）2 件**: `cookbooks/codex-cli/default.rb:53`, `cookbooks/functions/default.rb:56`(helper 既定)

bare 4 件は **2 つの正当な auth モデル**に分かれ、機械的に「全部 `--profile` 化」は誤り:

| cookbook | 実行先 | 正しい扱い |
|---|---|---|
| `cookbooks/mcp` | darwin / roles/llm / lxc-roon-mcp。darwin では `aws login` の **default profile** が正（memory 記録「mcp/codex-cli は default profile」） | **bare 維持**。`--profile pve-bootstrap-ssm` 化は Mac の MCP 認証を壊す |
| `cookbooks/codex-cli`(STS) | darwin。同上 | **bare/STS 維持**（allowlist + 理由コメント） |
| `cookbooks/lxc-hydra` | CT 106（LXC 専用） | **案 B migrate 対象**: 明示 `--profile` 化 |
| `pve/lxc-consent` | CT 110（LXC 専用） | **案 B migrate 対象**: 明示 `--profile` 化 |
| `cookbooks/memory-server` | （Phase 1 で削除） | **対象外** |

**案 B migrate の必須前提（着手前に probe、`~/.claude/rules/aws-iam.md`「Multi-profile auth chain —
enumerate every profile's IAM scope at design time」）**:

`/hydra/*` SSM path を**どの profile が読めるか**を確定してから migrate する。機械的に
`aws_profile`(=aws-config.json の `pve-bootstrap-ssm`)を入れてはならない —
`pve-bootstrap-ssm` は歴史的に `/ssh-keys/*` のみのスコープだった前例があり、elastic-agent は
`/monitoring/*` に `sh1admn` を使う（path 名前空間別に profile が異なる）。`/hydra/*` が
`pve-bootstrap-ssm` で読めない場合の選択肢: (a) home-monitor で IAM policy に `/hydra/*` +
`kms:Decrypt` を追加（cross-repo PR）、(b) 別 profile（sh1admn 等）を使う、(c) bare/operator-interactive
のまま据え置く。**probe で読めることを確認するまで migrate しない**。probe コマンド例:

```
! ssh root@192.168.1.10 'pct exec 110 -- aws ssm get-parameter --name /hydra/google-client-id \
    --with-decryption --query Parameter.Value --output text --profile pve-bootstrap-ssm >/dev/null 2>&1 \
    && echo OK || echo FAIL'
```

migrate 時は check_command **と** 実 `execute` ブロック内の全 `aws ssm` 呼び出しの両方に同じ
`--profile #{aws_profile}` を付ける（aws-config.json から読む既存パターン: elastic-agent:266 /
lxc-praeco:28 / auto-mitamae-target:30 を踏襲）。bare の execute はそれぞれ複数の `aws ssm` 行を持つ。

## 安全原則（全 Phase 共通・違反禁止）

このリポジトリは **auto-mitamae fleet** 配下にある: main へのマージは約 5 分以内に
19 ホストへ自動適用される（orchestrator は monitoring CT 上の cron 駆動）。よって:

1. **1 クラスタ = 1 PR**。削除と DSL 化を混ぜない。PR は CI green + dry-run diff 添付がマージゲート
2. **挙動保存の証明**: 各 PR で対象ホスト種の `./bin/mitamae local <entry>.rb --dry-run` 出力を
   before/after で取得し diff。差分ゼロ（またはリソース名変更のみ）を PR 本文に記載
3. **canary はグローバル mutex**: orchestrator の cron 退避（pause → canary CT 適用 → 機能検証 →
   merge → cron 復帰）は同時に 1 ストリームしか実行できない。並列ストリームは canary 窓を直列化すること。
   手順は `~/.claude/rules/infrastructure.md` "Auto-mitamae Fleet Cookbook Validation" に従う
4. **マージは直列**: 複数 PR を同時にマージしない。マージごとに fleet の
   `auto_mitamae_last_apply_status{result="success"}` を確認してから次をマージ
5. **mitamae 既知罠の遵守**（`~/.claude/rules/ruby.md` 全節）: トップレベル Ruby はコンパイル時評価 /
   owner は String / check_command は実呼び出しと同じ profile / skip_if の content-aware 化 /
   remote_file の not_if 設計 / WARN ログでの skip 通知
6. **mise 移行は `/verify-mise-backend` の 5-check 必須**（`~/.claude/rules/mise-migration.md`。
   PR #32 の 8 連続バグの再発防止）
7. cookbook 編集後は必ず `--dry-run`（プロジェクトフック準拠）

## Phase 0: 安全網整備（依存: なし）

成果物（PR 1 本に縮小。当初の PR 0-1 = consent への `--profile` 追加は撤回 —
consent の bare↔bare は規約違反ではなく、profile 統一は案 B として Phase 2 の lxc-hydra/lxc-consent
migrate に統合する）:

- [x] PR 0-2: ガードレール一式（#470）
  - `bin/audit-cookbook-reachability`（Ruby）: include グラフ BFS で未参照 cookbook を fail。
    allowlist 初期値 = 上の Dead 8 件（Phase 1 で空にする）
  - `bin/lint-cookbooks`（Ruby）: 検査群
    1. top-level `if/unless File.exist?`（allowlist: roles/manage:14）
    2. Integer `owner`/`group`（現状 0 件）
    3. **check_command profile MISMATCH**（presence ではなく、check_command 値と同一ブロックの
       実 `aws ssm` 呼び出しの profile 不一致を検出。値抽出は精密版 — 継続行・変数解決・
       instructions 除外。参考実装 `/tmp/.../classify_v2.rb`）。bare↔bare は合格。
       allowlist: codex-cli, cookbooks/mcp（darwin default-profile、理由コメント付き）
    4. notify 駆動 compose `up -d` の `--force-recreate` 欠落（block 単位）
  - `.github/workflows/test-setup.yml` の syntax-check job に両スクリプトを追加
  - `docs/refactoring/baseline.md`: cookbook 数 / 総行数 / クラスタ別対象数を記録

完了条件: CI green、baseline 記録済み。

## Phase 1: Dead code / 残骸削除（依存: Phase 0）

- [x] PR 1-1: dead 5 cookbook 削除（ruby, openssl, autoconf, disable-ipv6, im-select）（#471）
      + reachability allowlist から除去（8 → 3）
- [x] PR 1-2: 休眠 3 cookbook 削除（memory-server, oh-my-zsh, typewritten）（#472）
      + 参照コメントの掃除（`pve/lxc-memory.rb` の switch-back コメント、`cookbooks/dot-zsh/default.rb` 冒頭コメント）
      + allowlist を空にする（reachability: 137 total = 137 reachable, 0 allowlisted）
- [x] PR 1-3: `docs/adr/0005-impl/` 削除（ADR 0005 本体は残す。`.patch` 2 ファイルも削除）（このPR）
      + `docs/HANDOFF.md` 削除（中身ゼロのテンプレ、5/8 以降未使用 = stale）
      + `.patch` 参照していた `cookbooks/lxc-elasticsearch` の provenance コメント 2 箇所を git 履歴/ADR 参照へ更新（dangling 回避・comment-only）

検証: dry-run diff ゼロ（対象はそもそも実行されていない）。リスク最低。

## Phase 2: ヘルパー DSL 統合（依存: Phase 1。Phase 3 と並列可）

### 2-0: DSL 追加（先行 PR、functions を触るのはこの PR だけ）

- [x] PR 2-0: `cookbooks/functions/` に 2 ヘルパーを追加（適用はしない。定義のみ + 使用例コメント）（このPR）
  - `systemd_unit`: install + daemon-reload + enable + **restart/start** を 1 定義に。.service は
    `enable --now` でなく `restart`（編集が稼働中サービスに反映）、.timer は enable+restart timer+start
    companion service（"systemd Timer Verification Gate" の知見）。**staging は呼び出し元が行う** —
    define 内 `remote_file source "files/..."` は定義元 functions/ 基準で解決される mitamae の罠を回避
  - `deploy_with_ssm_env`: `require_external_auth` + generate 実行 + remote_file 配置 + temp 削除を
    1 定義に。**content-aware skip_if**（`expected_keys` の全キー存在チェック）を標準化
  - throwaway cookbook の dry-run で両 define の展開を検証（exit 0・install→activate 配線・auth skip 確認）

### 2-1〜: 適用 sweep（cookbook 単位で完結、並列可）

ルール: **1 cookbook は 1 ストリームが専有**し、その cookbook に関わる全パターン
（systemd_unit / compose_service / deploy_with_ssm_env）を同一 PR 系列で適用する。
パターン横断 sweep で同一ファイルを複数ストリームが触ることを禁止。

- [x] PR 2-1: `node-exporter` を systemd_unit に移行（#477、ユーザー判断で直接マージ）。
      converged host で no-op（unit 不変 → install は diff-gate で skip → activate 未 notify）。
      activation は enable --now→enable&&restart（初回 install 等価・unit 編集時に反映＝改善）
- [x] PR 2-2（G1）: **クローズ（実態空）**。2026-06-13 実態調査で systemd 手書き 17 件の大半が
      systemd_unit 非適合と判明（下記「Phase 2 sweep 実態調査」）。clean な適用は node-exporter のみで完了済み
- [~] PR 2-x（G2）: **canary 必須・実態は per-cookbook カスタマイズあり**（下記調査）。
      compose_service は monitoring/praeco の 2 件のみ（ES/kibana/apm は native systemd）。
      deploy_with_ssm_env は ~8 cookbook に余地あるが各々 skip_if/gate 数が異なり挙動改善=canary 必須
  - [x] G2-a `local-mcp`: deploy_with_ssm_env 採用（このPR）。cognee-shape に完全適合する唯一の clean fit。
        skip_if を content-aware（LLM_API_KEY/EMBEDDING_API_KEY 常時出力）に。**darwin 限定**なので
        Linux dry-run 不可 → 検証は (1) 実パラメータ throwaway で expansion 確認、(2) resource 名/path 完全保存、
        (3) **Mac apply で最終 functional 検証**。注: 採用で require_external_auth が helper 内に移り
        lint #3（profile MISMATCH）の視界外に → G2 採用拡大なら lint #3 を deploy_with_ssm_env 対応へ拡張要
  - [ ] G2-残: lxc-apm-server(keystore inject), lxc-kibana/elasticsearch(cert+multi-gate), lxc-monitoring(--remove-orphans),
        lxc-praeco, elastic-agent(3 gate) は cognee-shape 非適合 → helper 拡張か個別対応。lxc-hydra は案 B probe 先行

### Phase 2 sweep 実態調査（2026-06-13、baseline 概算の訂正）

**G1（systemd_unit sweep）は実態空** — baseline「systemd 17」は過大計上:

| cookbook | 実態 | 適合 |
|---|---|---|
| node-exporter | long-running service + files/ | ✓ #477 完了 |
| unbound-watchdog | system timer + oneshot service（[Install] なし） | △ helper に **install-only モード**が要 |
| lan-vpc-route | system service（files/）だが tailscale route-fix（table-52 sensitive） | △ 要 canary・個別 |
| s3-backup / aws-cost-monitor | `systemctl --user` は **README heredoc 内のドキュメント** | ✗ 実 resource でない |
| obsidian_file_sync | 実 `--user` timer（user-scope + inline 生成） | ✗ helper は sudo system のみ |
| lxc-mask-unsupported-units / lxc-systemd-hardening-fix | unit の mask/patch | ✗ install でない |
| edge-agent / lxc-roon | launchd / inline service | 個別扱い |

**G2 も「機械 sweep」でない** — 各採用が per-cookbook カスタマイズに当たる:

| cookbook | 手書きcompose | require_ext_auth | 採用余地 |
|---|---|---|---|
| lxc-monitoring | 2 | 2 | compose_service: 但し `--remove-orphans` 使用（helper default は `--build`）→ helper 拡張要。dws: 2 gate |
| lxc-praeco | 2 | 1 | compose_service 候補 + dws 1 |
| lxc-elasticsearch / lxc-kibana / lxc-apm-server | 0（native systemd） | 2/2/1 | dws のみ（compose なし） |
| lxc-hydra | 0 | 1 | **dws + 案 B profile（probe 先行必須）** |
| local-mcp | 0（compose_service 済） | 1 | dws 1 |
| mcp-probe | 0 | 1 | require_ext_auth あるが file-delete なし（別パターン） |
| claude-code | 0 | 0 | dws 非該当 |
| elastic-agent | 0 | 3 | dws 3 gate |

結論: G2 の真の価値は **deploy_with_ssm_env を ~8 cookbook に採用**（content-aware skip_if 標準化）。
ただし (a) 各 cookbook の既存 skip_if/generate を厳密に保存する per-cookbook 作業、(b) LXC サービスなので
**全て canary 必須**、(c) lxc-hydra は案 B probe 先行。compose_service は helper 拡張（`--remove-orphans` 等）が前提。
- [ ] 案 B 要件（SSM profile 統一、D5）— **独立 PR にしない**。`lxc-hydra` の bare→明示 `--profile` 化は
      その G2 PR に、`lxc-consent` の同変更は Phase 4 PR 4-3（inline 抽出）に**折り込む**
      （1 cookbook = 1 PR が同一ファイルを複数 PR で触らない原則）。共通の必須前提:
      上記「案 B（SSM profile 統一）スコープ」の probe（`/hydra/*` をどの profile が読めるか）を
      **migrate 着手前に実行**。読めない場合は home-monitor IAM policy 変更（cross-repo）か別 profile かを
      AskUserQuestion で確定。check_command と実 execute の全 `aws ssm` 両方に同じ `--profile` を付与。
      canary: consent は OAuth 実トークン round-trip 含む（`~/.claude/rules/adversarial-review.md`）。
      **mcp / codex-cli は対象外（darwin default-profile 維持）**

検証: dry-run diff（リソース名変更は対応表を PR に添付）+ LXC は canary で
`docker compose ps` / `elastic-agent status` / サービス固有機能プローブ。

## Phase 3: インストール手法統一（依存: Phase 0。Phase 2 と並列可、ただし対象 cookbook 排他）

- [x] PR 3-0: mise registry survey 実施（このPR、下記「Phase 3 mise survey」）。**結論: curl→mise の移行余地は
      ほぼ枯渇** — 大半の CLI ツールは既に mise 管理。残る唯一の marginal 候補は starship（aqua/cargo backend）
- [ ] PR 3-1〜: **要否はユーザー判断**（survey の通り候補が starship 1 件のみで低価値）。
      実施する場合も dev/CT104 への install 方式変更 = 実機 apply 検証が必要

### Phase 3 mise survey（2026-06-13、`mise registry` + install 方式実測）

| cookbook | 現 install | `mise registry` | 判定 |
|---|---|---|---|
| `starship` | darwin=brew / linux=curl | `aqua:starship/starship`, `cargo:starship` | **唯一の候補**: `mise use aqua:starship/starship` で brew+curl をクロス統一可。価値は中（brew は darwin で機能中、利得は linux 統一） |
| `gcloud-cli` | darwin/linux=curl+tar（公式 dl.google.com） | `vfox:`/`asdf:` plugin のみ（core なし） | **skip**: 公式 tarball が plugin backend より確実 |
| `speedtest-cli` | linux=curl+tar(Ookla) / darwin=brew tap | MISS | **skip**: Ookla は registry 外（`-universal` URL 特殊、mise-migration.md 既知） |
| `eternal-terminal` | darwin=brew / linux=apt repo | MISS | **skip**: apt/brew、tarball ツールでない |
| `zk` | 既に `mise_tool "zk-org/zk" backend "aqua"` + brew/curl fallback | MISS（aqua 指定で導入済） | **済**: 既に mise 管理 |
| `altserver` / `herdr` | curl install | MISS | **skip**: niche、registry 外 |
| `neovim` | 既に mise(aqua) | `aqua:neovim/neovim` | **済** |

既に mise 管理のツール群（bat/fd/jq/lazygit/fastfetch/golang/jdk/haskell/gemini-cli/git/macism/imgcat/zk/neovim 等）が示すとおり、本リポは過去に大半を mise 化済み。curl が残るのは「registry 外ツール」か「サービス成果物（node-exporter/elastic-agent）」。**PR 3-1 は starship のみ・低価値のため要否をユーザー判断とする。**
- [x] PR 3-R: ruby 3.3 一本化（D2）: roles/programming から ruby32 include 削除 + `cookbooks/ruby32` 削除（このPR）。
      3.2 依存の残存ゼロを確認。global は `roles/programming:13 global_version: "3.3"` で元から 3.3 →
      ruby32 削除で global は不変・ruby33 が 3.3.0 install 継続。rbenv は既存 3.2.1 をアンインストールせず
      （install 停止のみ）。roles/programming は linux/darwin/lxc-dev-workstation(CT104) が include → CT104 に届くが
      idempotent・サービス無影響
- [x] 調査タスク（PR なし、D3）: python / rust の mise 統一可否（このPR で調査完了。下記結論。実行は**ユーザー判断**）
  - **python（pyenv）**: mise core registry に `python` あり、`mise use python@3.12` で移行は技術的に可能。
    ただし (a) dev/CT104 の python 管理方式変更 = 挙動変更、(b) `~/.claude/rules/mise-migration.md` の
    **mise pipx 制約**（pipx を別途 PATH に要する / mise pipx の venv は `pipx inject` 不可）。
    pip extras を要するツール（git-remote-codecommit の `botocore[crt]` 等）は pyenv pip が必要。
    → **据え置き推奨**。移行するなら pipx 依存ツールの棚卸しが前提
  - **rust（rustup）**: mise に rust（rustup backend）あるが、rustup が rust の canonical manager
    （components / `rustup target add aarch64-apple-ios` 等）。`~/.claude/rules/ios-build.md` が
    rustup target 管理に依存。mise 経由は indirection 増で利得なし → **rustup 据え置き推奨**

## Phase 4: 構造リファクタ（依存: Phase 2）

- [x] PR 4-1: `pve/lxc-weave.rb`（284 行）→ `cookbooks/lxc-weave/` 抽出 + 薄いエントリ化（#480、**canary 検証済み**）。
      __FILE__ path を cookbook 規約（`"..", "ssh-keys"`）に修正。before/after dry-run diff で挙動保存実証。
      weave CT 実適用 exit 0・4 コンテナ稼働・weave-server "Up 11 days"（再起動なし＝no-op 確認）
- [x] PR 4-2: `pve/lxc-pro-router.rb`（224 行）→ `cookbooks/lxc-pro-router/` 抽出 + 薄化（#481、**canary 検証済み**）。
      __FILE__ path 修正。before/after dry-run diff 挙動保存実証。pro-router CT 実適用 exit 0・tailnet-routes active・
      table-52 の 192.168/16 ルート 0（LAN black-hole なし）・LAN 到達 OK
- [x] PR 4-3a: `pve/lxc-consent.rb`（181 行）→ `cookbooks/lxc-consent/` 抽出（verbatim、case-B は分離）（このPR、canary 待ち）。
      consent-app file-store path 修正（`../cookbooks/consent-app/files` → `../consent-app/files`）に伴い
      **reachability に sibling file-store パターン `../X/files` を追加**（consent-app の reachable 維持）。
      **before/after dry-run diff 完全一致（718 行・差分ゼロ）= 挙動保存**。require_external_auth は BARE 保持。
      canary: consent CT（OAuth 実トークン round-trip — `~/.claude/rules/adversarial-review.md` Live Token Gate）
- [x] PR 4-3b（案 B）: `lxc-consent` を bare→`--profile #{aws_profile}`(pve-bootstrap-ssm) 化（このPR）。
      home-monitor PR #95（pve-bootstrap-ssm に /hydra/* GetParameter + aws/ssm kms:Decrypt）を merge + apply 済み →
      **CT 110 で live decrypt probe DECRYPT_OK（IAM 伝播 ~60s 後）= grant 検証済み**。check_command + generate の
      全 /hydra/* read が pve-bootstrap-ssm 経由。lint #3 profile 一致。
- [ ] lxc-hydra は **case-B 対象外（保留）**: /hydra/* に加え **/memory/aurora-endpoint も読む**が pve-bootstrap-ssm は
      /memory/* 未許可（probe: MEMORY_FAIL）→ 完全移行には /memory/* grant が別途必要。現状 bare 据え置き（.env operator-seed で稼働）
- [x] PR 4-4: node attribute 規約整理 + roles 境界監査（このPR、CLAUDE.md に明文化）。
      **監査結果クリーン**: node[:setup]/[:homebrew]/[:profile] は host-profile に一元化済み（22 箇所の重複除去済み・
      散在代入なし）、roles 間で重複 include される cookbook はゼロ（各 cookbook は 1 role 専有）。修正不要、規約のみ明文化

## Phase 5: ガードレール恒久化・クローズ（依存: 全 Phase）

- [x] PR 5-1: CLAUDE.md「Custom Helpers」+「Conventions」に DSL（lxc_entry / compose_service /
      systemd_unit / deploy_with_ssm_env）+ thin-entry/guardrail 規約を明記（このPR・4-4 と統合）
- [x] PR 5-2: `docs/refactoring/result.md` を **final 化**（このPR）。Phase 4 + 4-3b 検証済み・fleet 19/19 を反映。
      cookbook 数は 145→136（dead/dormant 削除）→ 139（Phase 4 抽出で +3）。dead code ゼロ・allowlist 空・CI ガードレール稼働が実利得
- [x] retro 実施済み（rg `-E`・mitamae define source 解決・sweep 前分類の 3 学習）+ project memory に保存
      （[[mitamae-define-remote-file-source-resolution]] / [[setup-refactoring-phase2-scope]]）。Cognee 保存は MCP 接続時に追補

## 並列実行ガイド（ultracode / 複数ストリーム向け）

依存グラフ:

```
Phase 0 ─→ Phase 1 ─→ Phase 2-0 ─→ Phase 2 sweep（G1 / G2 並列）─→ Phase 4
      └──────────────→ Phase 3（Phase 2 と並列可）
全完了 ─→ Phase 5
```

ファイル排他表（ストリーム同時実行時の専有宣言）:

| ストリーム | 専有ファイル | 禁止 |
|---|---|---|
| S0（Phase 0） | bin/, .github/workflows/test-setup.yml, docs/refactoring/ | cookbooks/ への変更（lxc-consent 修正 PR 0-1 を除く） |
| S1（Phase 1） | 削除対象 8 cookbook dir, docs/adr/0005-impl/, docs/HANDOFF.md, pve/lxc-memory.rb, cookbooks/dot-zsh/default.rb, bin/audit-cookbook-reachability の allowlist | その他 cookbook |
| S2（Phase 2） | cookbooks/functions/（PR 2-0 のみ）、以降は担当 cookbook dir を PR ごとに宣言 | Phase 3 対象 cookbook |
| S3（Phase 3） | mise 化対象 cookbook dir + roles/programming/default.rb（PR 3-R のみ） | G1/G2 cookbook、elastic-agent |
| S4（Phase 4） | pve/lxc-{weave,pro-router,consent}.rb + 対応 cookbooks/lxc-*/ | その他 |

注: 案 B の profile 修正は所有 PR に折り込む（lxc-hydra→G2 の lxc-hydra PR、lxc-consent→PR 4-3）。
S2(G2) と S4 が `cookbooks/lxc-hydra` / `pve/lxc-consent.rb` を分担するので、両ストリーム同時稼働時は
これらファイルの担当 PR が確定するまで他方は触らないこと。

グローバル制約:

- **canary mutex**: canary（orchestrator cron 退避を伴う検証）は全ストリームで同時 1 件。
  着手前に本ファイルの「canary 実行中: <stream/PR>」行を更新して宣言し、復帰時に消す
- **マージ直列化**: マージ権はオーケストレータ（親セッション）が持ち、PR 完成順に 1 本ずつ。
  マージ間に fleet health（auto_mitamae metrics）確認
- 各ストリームは worktree 分離で作業し、`gh pr create --head <branch>` で明示ブランチ指定
- スコープ外の問題を発見したら修正せず本ファイル末尾の「発見事項」に追記して親に報告

canary 実行中: （なし）

## 発見事項（スコープ外、要トリアージ）

- **2026-06-13 解決済み**: 当初 plan が「check_command に `--profile` 無し = 違反」とした見立ては誤りだった。
  正しくは profile MISMATCH 検出（D5 / 案 B スコープに反映済み）。lxc-hydra・lxc-consent の bare↔bare は
  規約上は合格だが、案 B として明示 profile へ統一する（fleet 一貫性 + cold-boot 自動化のため）。
- **要トリアージ**: `pve/lxc-consent.rb` 冒頭コメントが `cookbooks/hydra/files/generate_env.sh` を参照するが
  `cookbooks/hydra/` は存在しない（`lxc-hydra` にリネーム済み）。stale doc 参照 → Phase 4 PR 4-3 で掃除。
- **要トリアージ**: `/hydra/*` SSM path の読み取り profile が未確定（案 B の前提 probe で確定する）。
  `pve-bootstrap-ssm` で読めなければ home-monitor の IAM policy 変更（cross-repo PR）が派生する可能性。
- **本セッションの環境制約**: このセッションから `ssh root@192.168.1.10` が `Host key verification failed`。
  CT 110 等の実機 probe は親/ユーザーが `!` で実行する必要がある。
- **2026-06-13 Phase 0 で確定**: `consent-app` は dead ではなく file-store cookbook
  （`include_cookbook` されず `pve/lxc-consent.rb:58` が `File.read(cookbooks/consent-app/files/…)` で消費）。
  `bin/audit-cookbook-reachability` は file-store エッジ（非コメント行の `cookbooks/X/files` 参照）で
  真に reachable 化し allowlist しない。
- **2026-06-13 Phase 0 発見（要トリアージ）**: `cookbooks/self-heal/` は git 追跡 0・空ディレクトリ＝
  ローカル cruft（git に存在しない）。リポジトリへの影響なし。気になればローカルで `rmdir` のみ。
- **2026-06-13 Phase 0 実測でスコープ修正（Phase 2 G2 に影響）**: 手書き docker-compose `up -d` クラスタは
  実測 **2 件**（`lxc-monitoring` / `lxc-praeco`）で plan 概算「10」と乖離。`compose_service` DSL は既に
  6 recipe（lxc-cognee/lxc-memory/lxc-roon-mcp/local-mcp/pve/lxc-weave/pve/lxc-consent）が採用済み。
  systemd 4 ステップ手書きも `daemon-reload` proxy で実測 **17**（概算 24）。詳細 `docs/refactoring/baseline.md`。
- **2026-06-13 Phase 0 adversarial audit で修正済み**: reachability の初版は `def lxc_entry` 本体の
  `include_role "lxc-core"` / `include_cookbook "elastic-agent"` を偽エッジ化していた（`def` 行のみ skip）。
  lxc_entry 撤去時に subtree が orphan でも CI が green になる latent risk。def 本体全体を skip するよう修正し、
  lxc-core/elastic-agent は実 `lxc_entry()` 呼び出し経由のみ reachable に。HEAD は 19 個の実呼び出しで 137/8 維持。
