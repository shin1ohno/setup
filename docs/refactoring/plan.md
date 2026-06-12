# Setup リポジトリ全面リファクタリング計画（2026-06）

Status: **Phase 0 着手前**。本ファイルが進捗台帳の正本。各 PR のマージ時にチェックボックスを更新し、完了 Phase はマージコミットへのリンクを残すこと。

## 決定事項ログ

| # | 決定 | 日付 |
|---|---|---|
| D1 | 休眠 3 cookbook（memory-server / oh-my-zsh / typewritten）も削除する（git 履歴から復元可能） | 2026-06-13 |
| D2 | Ruby は 3.3 一本化。ruby32 を削除（roles/programming から include を外す） | 2026-06-13 |
| D3 | python / rust の mise 統一は Phase 3 で**調査のみ**。実行は調査結果を見てユーザーが判断 | 2026-06-13 |
| D4 | 本プランは docs/refactoring/plan.md にコミットし進捗台帳を兼ねる | 2026-06-13 |

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
- `check_command` に `--profile` なし:
  - 真の違反: `pve/lxc-consent.rb:131`（/hydra/google-client-id の SSM read に profile 指定なし）→ **Phase 0 で単発修正 PR**
  - 意図的: `cookbooks/codex-cli/default.rb:53`（darwin では `aws login` + default profile 運用が正。allowlist + コメント）
  - 誤検知に注意: 継続行（`" \` 改行 `"--profile ..."`）や変数渡し（`orchestrator_ssm_check` 等）があるため、
    lint は**複数行・変数解決対応**で実装すること（単純 grep 不可）
- notify 駆動 `docker compose up -d` の `--force-recreate` 欠落: lint 実装時に block 単位で再確認

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

成果物（PR 2 本）:

- [ ] PR 0-1: `pve/lxc-consent.rb:131` の check_command に `--profile` を追加（単発バグ修正、canary: lxc-consent）
- [ ] PR 0-2: ガードレール一式
  - `bin/audit-cookbook-reachability`（Ruby）: include グラフ BFS で未参照 cookbook を fail。
    allowlist 初期値 = 上の Dead 8 件（Phase 1 で空にする）
  - `bin/lint-cookbooks`（Ruby）: 4 検査（top-level File.exist? / Integer owner / check_command profile /
    compose force-recreate）。複数行・変数解決対応。allowlist: roles/manage, codex-cli（理由コメント付き）
  - `.github/workflows/test-setup.yml` の syntax-check job に両スクリプトを追加
  - `docs/refactoring/baseline.md`: cookbook 数 / 総行数 / クラスタ別対象数を記録

完了条件: CI green、baseline 記録済み。

## Phase 1: Dead code / 残骸削除（依存: Phase 0）

- [ ] PR 1-1: dead 5 cookbook 削除（ruby, openssl, autoconf, disable-ipv6, im-select）
      + reachability allowlist から除去
- [ ] PR 1-2: 休眠 3 cookbook 削除（memory-server, oh-my-zsh, typewritten）
      + 参照コメントの掃除（`pve/lxc-memory.rb` の switch-back コメント、`cookbooks/dot-zsh/default.rb` 冒頭コメント）
      + allowlist を空にする
- [ ] PR 1-3: `docs/adr/0005-impl/` 削除（ADR 0005 本体は残す。`.patch` 2 ファイルも削除）
      + `docs/HANDOFF.md` 鮮度監査（stale なら削除 or 更新）

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

グローバル制約:

- **canary mutex**: canary（orchestrator cron 退避を伴う検証）は全ストリームで同時 1 件。
  着手前に本ファイルの「canary 実行中: <stream/PR>」行を更新して宣言し、復帰時に消す
- **マージ直列化**: マージ権はオーケストレータ（親セッション）が持ち、PR 完成順に 1 本ずつ。
  マージ間に fleet health（auto_mitamae metrics）確認
- 各ストリームは worktree 分離で作業し、`gh pr create --head <branch>` で明示ブランチ指定
- スコープ外の問題を発見したら修正せず本ファイル末尾の「発見事項」に追記して親に報告

canary 実行中: （なし）

## 発見事項（スコープ外、要トリアージ）

- （随時追記）
