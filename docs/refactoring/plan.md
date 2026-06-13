# Setup リポジトリ全面リファクタリング計画（2026-06）

Status: **Phase 1 完了（#470 Phase0 / #471 #472 + 本PR Phase1）。Phase 2 着手可（Phase 3 並列可）**。本ファイルが進捗台帳の正本。各 PR のマージ時にチェックボックスを更新し、完了 Phase はマージコミットへのリンクを残すこと。

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

- [ ] PR 2-0: `cookbooks/functions/` に 2 ヘルパーを追加（**適用はしない**。定義のみ + コメントで使用例）
  - `systemd_unit`: staging → `sudo install` → daemon-reload → enable → **restart timer/service**
    の定型を 1 定義に。`~/.claude/rules/infrastructure.md` の "systemd Timer Verification Gate"
    （enable --now では更新が反映されない / `Trigger:` 検証）の知見を実装に焼き込む
  - `deploy_with_ssm_env`: `require_external_auth` + generate_env.sh 実行 + remote_file 配置 +
    temp 削除の定型。**content-aware skip_if**（期待キーの存在チェック）を標準にする

### 2-1〜: 適用 sweep（cookbook 単位で完結、並列可）

ルール: **1 cookbook は 1 ストリームが専有**し、その cookbook に関わる全パターン
（systemd_unit / compose_service / deploy_with_ssm_env）を同一 PR 系列で適用する。
パターン横断 sweep で同一ファイルを複数ストリームが触ることを禁止。

- [ ] PR 2-1: canary 検証 PR — `node-exporter`（systemd_unit の初適用）を canary CT で機能検証
      （`systemctl show --property=Trigger` / :9100 scrape 確認）。fix shape をここで確定
- [ ] PR 2-2〜: グループ G1（systemd 単純系）: s3-backup, unbound-watchdog ほか systemd 手書き 24 cookbook の残り。
      2-4 cookbook ずつ機械 sweep
- [ ] PR 2-x: グループ G2（LXC サービス系、compose + ssm env + systemd 混在）:
      lxc-monitoring, lxc-praeco, lxc-elasticsearch, lxc-kibana, lxc-apm-server, lxc-hydra,
      local-mcp, mcp-probe, claude-code, **elastic-agent**（※ elastic-agent は Phase 3 対象外とし G2 に専属）。
      各 cookbook 1 PR、LXC 系は canary 必須
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

- [ ] PR 3-0: 対象候補（gcloud-cli, neovim, speedtest-cli, zk, starship fallback 等。
      elastic-agent は G2 専属のため**除外**）全ツールへ `/verify-mise-backend` 5-check を一括実行し、
      結果表を本ファイルに追記
- [ ] PR 3-1〜: 5-check 通過ツールのみ `mise_tool` 化（2-3 cookbook / PR）。
      不通過ツールは curl+tar のまま（必要なら共通 `download_install` ヘルパー化を Phase 5 で判断）
- [ ] PR 3-R: ruby 3.3 一本化（D2）: roles/programming から ruby32 include 削除 + `cookbooks/ruby32` 削除。
      事前に `rg 'ruby.?3\.2|\.ruby-version'` で 3.2 依存の残存を確認
- [ ] 調査タスク（PR なし、D3）: python（pyenv 89 行）/ rust（rustup 22 行）の mise 統一可否。
      pipx backend 制約（`~/.claude/rules/mise-migration.md`）を踏まえ結果を本ファイルに追記し、
      実行可否は**ユーザー判断を仰ぐ**

## Phase 4: 構造リファクタ（依存: Phase 2）

- [ ] PR 4-1: `pve/lxc-weave.rb`（284 行）のインラインロジックを `cookbooks/lxc-weave/` へ抽出。
      薄いエントリ（node override + include）形式に統一。canary: weave CT
- [ ] PR 4-2: `pve/lxc-pro-router.rb`（224 行）同上。canary 必須 +
      機能プローブに `~/.claude/rules/tailscale.md` の table-52 検証（`ip rule show` / LAN 到達性）を含める
- [ ] PR 4-3: `pve/lxc-consent.rb`（181 行）同上。canary: consent CT（OAuth フローの実トークン round-trip を含める —
      `~/.claude/rules/adversarial-review.md` Live Token Gate）
- [ ] PR 4-4: node attribute 規約整理（`node[:setup][:*]` 等のデフォルト解決を host-profile に集約済みか監査、
      規約を CLAUDE.md に明文化）+ roles 境界監査（core/foundation/extras の重複 include 検出）

## Phase 5: ガードレール恒久化・クローズ（依存: 全 Phase）

- [ ] PR 5-1: CLAUDE.md「Cookbook Best Practices」に新 DSL（systemd_unit / compose_service /
      deploy_with_ssm_env）の使用を明記。README / docs の更新
- [ ] PR 5-2: `docs/refactoring/result.md` に baseline 比較（cookbook 数 145 → 目標 ~135、行数 -10% 前後）
- [ ] Cognee へ結論保存 + retro 実施（PR 不要）

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
