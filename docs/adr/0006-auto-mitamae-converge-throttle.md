# ADR 0006: auto-mitamae fleet converge — 二段階カデンス (drift-gated throttle)

**Status**: Accepted (2026-06-27)

## Context

フリート self-update (`cookbooks/auto-mitamae-*`) は push 型:

- monitoring LXC (CT 111) の cron が `drift-checker.sh` (2分) で `origin/main` HEAD を観測、
  `orchestrator.sh` (5分) が `hosts.json` の全ホストへ SSH (forced-command) で
  `mitamae-runner.sh <role> <expected-sha>` を**逐次** push。
- `mitamae-runner.sh` は受信側で `git fetch` → `reset --hard` / `clean` / `checkout <sha>`
  → `./bin/mitamae local <role>` を実行。

問題は **`mitamae-runner.sh` が git drift の有無に関わらず毎サイクル `./bin/mitamae local`
をフル実行**していた点。フリートの 18 LXC は**すべて同一の Proxmox 物理ホスト上**で動くため、
新規コミットが無くても 5 分ごとに全 LXC がフル converge し、共有ホストの CPU/IO が
mitamae 負荷でほぼ常時占有される (ユーザ報告: 「一度にすべてのコンテナがアップデートを行うので
過負荷」)。orchestrator は逐次だが、毎サイクル全ホストを回すため負荷は連続的だった。

`./bin/mitamae local` が負荷源であり、`git fetch` / `reset` / `clean` / `checkout` の
ローカル git 操作はサブ秒で負荷源ではない。

## Decision

**`mitamae-runner.sh` に二段階の converge カデンスを導入する** (orchestrator 側は status
パススルーのみ、変更なし):

| 状況 | 挙動 |
|---|---|
| `drift > 0` (新規 origin/main コミット) | **即 converge**。コードロールアウト速度・canary ゲートは不変 |
| `drift == 0` (既に target SHA) | `RECONCILE_INTERVAL_SEC` (既定 1h) + ホスト毎ジッターの reconcile 窓まで `status=up_to_date` で即スキップ。設定ドリフト補正のための reconcile のみ低頻度で実行 |

設計上の要点:

1. **安価な再アンカー (`reset --hard` / `clean` / `checkout`) は throttle より前に毎サイクル実行**。
   これは負荷源ではなく、CT103 不変条件 (host は常に `expected_sha` を追従、ローカル改変は
   非権威) を維持するため。`drift==0 ≠ HEAD==expected_sha` (ローカル先行コミットでも
   `HEAD..origin/main` は 0) なので、無条件 `checkout` が HEAD を確実に `expected_sha` へ戻す。
2. **高価な `./bin/mitamae local` のみを throttle**。
3. **ジッターは role パスのハッシュ由来** (`cksum % (JITTER+1)`)。フリート同期適用 (コミット着弾時に
   全ホストが同時 converge) の後、各ホストの次回 reconcile が単一サイクルに再同期する
   thundering-herd を防ぐ。実測で reconcile が約 62–120 分に分散 = 1 サイクルあたり ~1.5 ホスト。
4. **stamp は `/var/lib/auto-mitamae/last-converge.epoch`** (= `/root/setup` の外。`git clean -fdq`
   で消えない)。成功 converge 時のみ更新 (失敗は throttle せず毎サイクル再試行 + alert)。
5. **stamp サニタイズ + クロッククランプ**: 非数値 body は `set -u` で status 行出力前に abort
   → silent `ssh_unreachable` を招くため `^[0-9]+$` で検証。未来 stamp (NTP 未同期→巻き戻し) は
   永久 throttle を招くため `now` 超過を 0 にクランプ。`set -e` 安全のためクランプは
   `cond && action` でなく `if/then/fi`。

定常負荷: 「19 converge / 5 分」→ ジッター分散された「~1.5 converge / サイクル」(≈ -94%)。

## Consequences

- **トレードオフ**: 設定ドリフト (誰かが LXC 上の config を手で変更) の自動補正レイテンシが
  最大 5 分 → 最大 ~2h (= INTERVAL + JITTER) に伸びる。新規コミットのコードロールアウトは不変
  (drift>0 は即時)。ユーザの最優先事項 (過負荷解消) を満たす妥当なバランス。即時フル適用が
  必要な場合は `bin/apply-pve-lxcs` (mitamae 直叩き、runner をバイパス) が残る。
- **監視**: `status=up_to_date` は healthy 扱い。failing 系 regex
  (`mitamae_fail|git_fetch_fail|invalid_command`) に非該当、apply timestamp は毎サイクル
  refresh されるため `AutoMitamaeApplyStale` は誤発火しない。canary ゲートも非ブロック。
  既存アラート (`cookbooks/lxc-monitoring/files/alerts/auto-mitamae.yml`) の変更は不要。
- **チューニング**: フリート挙動の変更は runner 内の `RECONCILE_INTERVAL_SEC` /
  `RECONCILE_JITTER_SEC` 定数を編集 (同 self-update 機構でロールアウト)。`AUTO_MITAMAE_*` env
  override は forced-command パスには届かず、手動/ローカルテスト用のみ。
- **Rollback**: 2 ファイルの revert で復帰。stamp ファイルは残っても無害 (inert)。

## Rejected alternatives

- **orchestrator 側でホストをサイクル間シャーディング** (N ホスト/サイクル): 新規コミットの
  ロールアウトがシャード待ちで遅延。orchestrator は config ドリフトを観測できず、reconcile 判断を
  ホスト側で持てない。却下。
- **load-average ゲート** (`uptime` 闾値で skip/delay): 反応的で根本の冗長 converge を減らさない。
  二段階カデンスと併用は可能だが、まず冗長 converge の排除で十分。却下。
- **drift==0 を恒久 skip** (config ドリフト補正を廃止): 手動変更の自動是正という現行設計の
  価値を失う。低頻度 reconcile で両立させる方を採用。
- **per-LXC プル型タイマー** (各 LXC が自前 cron/timer で apply): 固定スケジュールだと全 LXC が
  同一壁時計分に発火し thundering-herd。push 型 + runner throttle の方が中央制御 (canary/SHA
  ピン) を保てる。却下。
