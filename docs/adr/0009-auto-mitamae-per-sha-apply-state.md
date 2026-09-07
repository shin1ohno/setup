# ADR 0009: auto-mitamae — 適用成功状態を SHA 単位で管理し、canary gate は検証済み SHA だけ通す

**Status**: Proposed (2026-09-07、adversarial 設計レビュー + 実装 diff レビュー反映済み — `0009-review-design.md`, `0009-review-diff.md`) — supersedes the time-only stamp of ADR 0006 (ADR 0006 の二段階カデンス自体は維持)

## Context

ADR 0006 は `mitamae-runner.sh` に「drift>0 なら即 converge、drift==0 なら reconcile 窓まで
`up_to_date`」の二段階カデンスを導入した。抑制判定の根拠は
`/var/lib/auto-mitamae/last-converge.epoch` に書く **成功時刻だけ** で、どの SHA が成功したかは
保存していない。

隔離再現（`design-review/runner-reproduction.json`、本番スクリプトのパスだけ置換、ローカル
origin + 成功/失敗を返す mitamae 代替）で次の状態遷移が確認された:

| 周期 | 入力 | runner の応答 | mitamae 呼出累計 |
|---|---|---|---|
| 初期 | A | `success`（stamp 更新） | 1 |
| 新版 | B | `mitamae_fail`（HEAD は apply 前に B へ checkout 済み） | 2 |
| 次周期 | 同じ B | `up_to_date`（drift=0 かつ A の stamp が窓内） | 2 |

runner は apply **前** に HEAD を expected_sha に進めるので、B の apply が失敗しても次周期は
drift==0 になり、A の成功時刻で抑制条件が成立する。B は A の reconcile 窓（INTERVAL + jitter、
最大約 2 時間）が閉じるまで再試行されない。恒久停止ではなく窓内の誤抑制だが、その窓内に
orchestrator が下記のとおり fleet へ展開してしまう。

`orchestrator.sh` はこの `up_to_date` を canary success と同一視するため、失敗した B が fleet に
展開される（`orchestrator-reproduction.json` の `next_B_skip`）。さらに canary が
`ssh_unreachable` / `lock_held` / `sha_mismatch` の場合も「transient」として fleet phase へ進む
（同 `unreachable`）。canary が何も検証していない SHA を fleet に配る経路が 2 本ある。

## Decision

### runner: 状態を「成功 SHA + 成功時刻 + 直近試行の SHA と成否」に拡張し、原子的に保存する

保存先は `/var/lib/auto-mitamae/apply-state`（`git clean -fdq` の対象外。ADR 0006 と同じ理由）。
`key=value` 行の平文で、`tmp に書いて mv` で置換する（部分書き込みを読まない）。

```
last_success_sha=<40hex>
last_success_role=<role path>
last_success_epoch=<int>
last_attempt_sha=<40hex>
last_attempt_status=in_progress|success|mitamae_fail
last_attempt_epoch=<int>
```

読取は行ごとの `key=value`（末尾改行なしの最終行も処理）で、重複キー・未知キーは記録全体を無効化、epoch は
先頭ゼロなしの十進 12 桁以内だけを数値と読む（bash の 8 進解釈で status 行の前に abort する経路を塞ぐ）。
状態の保存に失敗した場合は `status=state_write_fail`（exit 1、`verified_sha` なし）で応答し、apply 前の
保存失敗なら mitamae を呼ばない。orchestrator はこの status を hold として扱う。

抑制（`status=up_to_date` で mitamae を呼ばない）の条件は次の **全て** が成立する場合に限る:

1. `drift == 0`（origin/main に新規コミットがない）
2. `last_success_sha == expected_sha` かつ `last_success_role == role`（この SHA と role の組で
   成功した実績がある。role は Git SHA と独立した入力なので、hosts.json で role を差し替えた
   ホストが旧 role の成功を引き継いではならない — レビュー F2）
3. `last_attempt_status == success`（直近の試行が失敗も中断もしていない）
4. `now < last_success_epoch + RECONCILE_INTERVAL_SEC + host_jitter`（ADR 0006 の窓、不変）

1 つでも欠ければ converge する。結果として:

- A 成功 → B 失敗: 次周期は 2 が不成立 → B を再試行する。
- 同一 SHA の定期 reconcile が失敗: 3 が不成立 → 次周期に再試行する。通常経路では定期 reconcile
  に入れた時点で窓は閉じているので時刻 stamp だけでも再試行される（レビュー F7）が、interval
  変更・時計巻き戻し・中断の経路では窓内に戻り得るため、直近試行の成否で明示的に塞ぐ。
- apply 中断（reboot / OOM / 手動 ^C）: apply の **前** に `last_attempt_status=in_progress` を
  書くので、最終結果が書かれずに死んでも 3 が不成立 → 次周期に再試行する（レビュー F3）。
- 検証済み同一 SHA: 1〜4 成立 → 抑制（負荷抑制・jitter は不変）。

書き込みは 3 回: apply 直前に `last_attempt_*`=in_progress（`last_success_*` は保持）、成功時に
全フィールドをこの SHA・role に更新、失敗時に `last_attempt_*` だけ更新（`last_success_*` は最後に
成功した組を保持し続ける）。すべて flock の区間内。状態ファイルの sanitize は ADR 0006 と
同じ方針: 欠落・非数値・未来時刻・40hex でない SHA・role 形式外は「成功実績なし」と読み、
converge に倒す（`source` はしない、行ごとの `key=value` 読取）。

status 行には `verified_sha=<sha>` を **追加**する（既存フィールドの後ろ、`ts=` の前）。orchestrator は
status 行 1 本を空白区切りの `key=value` token として解析し、キーは token 全体一致、SHA は 40 hex 全体一致、
重複キーがあれば SHA 系フィールドを捨てる（`not_verified_sha=` や末尾に非 hex を付けた応答は pass しない）。
`up_to_date` のとき値は expected_sha と等しい。`success` のときも同じ値を載せ、orchestrator は
「この応答は expected_sha の成功実績に裏打ちされている」と機械的に読める。旧 orchestrator の
`grep -oE 'sha=[a-f0-9]+' | head -1` は先に現れる `sha=` を取るので互換。

移行: 旧 `last-converge.epoch` は読まない（SHA が不明なので「成功実績なし」と等価。未検証の時刻
stamp を新証跡へ昇格させない）。この変更のコミットが着弾した周期は、各ホストで **旧 runner**（bash
は起動時に読み込んだ旧スクリプトを実行し続け、cookbook は次回用の新 runner を install するだけ）が
apply を実行して旧 stamp を書く。新形式の状態はまだ無いので、次周期の新 runner は同じ SHA を
もう一度 converge し、その成功で初めて `apply-state` が書かれる（レビュー F5）。つまり移行時に
**1 周期分の fleet 再 converge が 1 回**発生する。これはコミット着弾 1 回分と同じ負荷で、以後は
発生しない。成功時に旧 stamp を削除する。canary の自己更新 apply が失敗した場合、旧 runner は
窓内 `up_to_date` を返し続け、新 orchestrator（監視 LXC が fleet phase で更新された後）はそれを
hold する。旧窓が閉じた時点で旧 runner が再試行し、成功すれば新 runner に切り替わる。

### orchestrator: canary gate は「expected_sha の成功を確認できた」応答だけ通す

| canary の応答 | gate | fleet phase |
|---|---|---|
| `success` かつ `sha == expected_sha` | pass | 実行 |
| `up_to_date` かつ `verified_sha == expected_sha` | pass | 実行 |
| `up_to_date` で `verified_sha` 欠落 / 不一致（旧 runner・未検証） | **hold** | 実行しない、次 cron で再試行 |
| `ssh_unreachable` / `lock_held` / `sha_mismatch` | **hold** | 実行しない、次 cron で再試行 |
| `mitamae_fail` / `git_fetch_fail` / `invalid_command` | fail | 実行しない（従来どおり abort） |

hold は失敗ではない（`AutoMitamaeCanaryFailing` は従来の regex のまま発火しない）。ただし
hold が続けば展開が止まるので、`auto_mitamae_canary_gate{result="pass|hold|fail"}` を新設し、
`hold` が 30 分続いたら warning を出す `AutoMitamaeCanaryHeld` を追加する。この gate 系列は
周期途中の publish（canary ごとに全体を置換する）でも前周期の値を引き継いで出し続け、複数 canary
の途中で Prometheus が評価しても `for: 30m` がリセットされないようにする（レビュー F6）。

fleet 側の per-host 系列は、hold でも従来の abort でも **その周期は出力されない**（publish は
tmp を全体置換するので、未処理ホストの系列は消える）。これは現行動作のままで変更しない:
前周期の値を引き継ぐと古い timestamp で `AutoMitamaeApplyStale` が fleet 全台で鳴り、
`CanaryFailing` / `CanaryHeld` と重複する。原因を示すのは canary 側の 2 アラートである。

hosts.json は flock 取得後に **1 回だけ** 読んでスナップショットにし、配列であること・各エントリの
host/user/role/label が文字列であること・canary が 1 台以上あることを jq で検証する。検証に落ちたら
何も ssh せず exit 1（レビュー F1: canary 0 台の gate は空虚に pass する）。両 phase は同じ
スナップショットを回すので、apply 中の hosts.json 更新は次周期から効く。

複数 canary がある場合は全 canary が pass のときだけ fleet へ進む。fail が 1 台でもあれば fail、
そうでなく hold が 1 台でもあれば hold。`success` でも `sha` が expected_sha と異なる応答、表に
ない status は hold。

### 検証（回帰テスト）

`cookbooks/auto-mitamae-target/test/run-state-scenarios.sh` が hermetic な一時ディレクトリに
ローカル origin・clone・成功/失敗を切り替えられる mitamae 代替・`ssh` 代替を作り、本番スクリプトを
**そのまま**（パスは `AUTO_MITAMAE_*` env override で差し替え。runner は `SSH_CONNECTION` が設定された
プロセス = ssh セッションでは override を無視するので、sshd の AcceptEnv 設定に関係なく本番入口は既定値で
動く — `restrict` は env を制約しないため、この pin が保証の根拠）実行して次を PASS させる:

1. A 成功 → B 失敗 → 同じ B を再試行する（`up_to_date` を返さない）→ B 成功 → 以後 `up_to_date`
2. 同一 SHA の定期再適用が失敗 → 次周期で再試行する
3. canary が `ssh_unreachable` / `lock_held` / `sha_mismatch` / `verified_sha` 欠落の `up_to_date` /
   別 SHA の `success` / 未知 status / `mitamae_fail` のとき fleet ホストへ ssh しない。`success` /
   検証済み `up_to_date` のときだけ ssh する。複数 canary の pass+hold → hold、pass+fail → fail。
   canary 0 台・破損 JSON の hosts.json は誰にも ssh せず exit 1
4. 検証済み同一 SHA では mitamae 呼出回数が増えない（負荷抑制の維持）。同 SHA で role が変われば
   converge する。apply 中断後は次周期に converge する

旧スクリプト（ADR 0009 以前）に対して同じハーネスを走らせると、Context の再現どおり「同じ B が
`up_to_date`」「unreachable canary で fleet に ssh」で FAIL する（positive control）。

CI の `syntax-check` job（ubuntu）でこのスクリプトを実行する。

## Consequences

- 失敗した SHA は毎周期再試行される（ADR 0006 が意図し、時刻 stamp では実現できていなかった挙動）。
  再試行のたびに `AutoMitamaeApplyFailing` の対象になるのは従来と同じ。
- canary が到達不能・ロック中・SHA 不一致のあいだ fleet 展開は止まる。従来は「transient」として
  fleet へ進んでいたが、それは canary が何も検証していない SHA を配る経路だった。停止時間は次周期
  （5 分）単位で、hold の可視化を metric とアラートで補う。
- 旧 runner と新 orchestrator が混在する移行窓では、旧 runner の `up_to_date`（`verified_sha` なし）
  は hold になる。canary はこの変更のコミットで drift>0 → converge → `success` を返すので、その周期で
  gate は pass し fleet へ進む。以後は新 runner が `verified_sha` を返す。
- 状態ファイルは 6 行の平文。`jq` 等の依存を runner に増やさない。
- canary の runner / mitamae がリモート側で残留し flock を握り続けると（orchestrator の 300s は
  ローカル ssh の期限で、リモートプロセス群を止めない）、`lock_held` が続き fleet は hold し続ける。
  これは従来「transient」として fleet に進んでいた経路を閉じた結果で、`AutoMitamaeCanaryHeld` の
  runbook にロック残留の確認を含める。runner 側の apply 期限（プロセス群の回収）は本 ADR の範囲外
  として TODO.md に記録（レビュー F4）。
- Rollback: 2 スクリプトの revert。状態ファイルは残っても無害。

## Rejected alternatives

- **失敗時に HEAD を旧 SHA へ戻す**（apply 失敗を drift>0 に見せかける）: 次周期の `git checkout`
  で再び B に進むだけで、途中で HEAD が揺れる。CT103 不変条件（host は常に expected_sha を追従）
  に反する。却下。
- **stamp に成功 SHA だけ追加**（直近試行の成否を持たない）: 通常経路の定期 reconcile 失敗は窓外で
  起きるので時刻 stamp だけでも再試行される（レビュー F7 の指摘どおり、当初の却下理由は誤り）。
  それでも「apply 前に証跡を無効化する」遷移は必要で（中断・巻き戻し）、`in_progress` を含む
  `last_attempt_*` はその無効化と、運用時の診断（最後の失敗 SHA と時刻を `cat` で読める、runbook が
  参照する）を兼ねる。証跡を成功 2 フィールドだけに縮める F7 の最小案は、無効化の遷移は採用し、
  フィールド削減は診断価値のため不採用。
- **orchestrator 側だけで直す**（canary が `up_to_date` のときは常に hold）: 定常状態で全周期 hold
  になり fleet の reconcile が止まる。runner が検証済みであることを応答に載せる方が単純。却下。
- **JSON 状態ファイル**: runner に `jq` 依存を追加する。`key=value` の 5 行で十分。却下。
- **canary の transient を N 回まで許容して fleet へ進む**: 「何も検証していない SHA を配らない」
  という不変条件に例外を作る。hold の可視化（metric + alert）で運用上の停止は見えるので不要。却下。

## Review（adversarial, codex — `docs/adr/0009-review-design.md`）

| # | 所見 | 採否 | 反映 |
|---|---|---|---|
| F1 | canary 0 台・hosts.json の別読みで gate が空虚に pass | 採用 | flock 後に 1 回だけ読取、jq 検証（配列・必須文字列・canary ≥1）、不合格は ssh せず exit 1。両 phase は同一スナップショット |
| F2 | 成功証跡に role が無く、同 SHA の role 変更が検証済み扱い | 採用 | `last_success_role` を追加し条件 2 に role 一致を含める。fleet は 1 ホスト 1 role なので証跡はホスト単位 1 組のまま |
| F3 | 中断した apply が旧成功を残す | 採用 | apply 直前に `last_attempt_status=in_progress` を書く。ハーネスに「mitamae が runner を kill → 次周期 converge」を追加 |
| F4 | ssh 300s はリモート lock 解放を保証せず hold が続く | 部分採用 | 本 PR では runner 側 apply 期限を入れない（既存挙動で、新 gate は隠さず `CanaryHeld` で可視化する）。runbook にロック残留確認、TODO.md に期限設計を記録 |
| F5 | 「追加 converge なし」は誤り（初回成功は旧 runner が書く） | 採用（文書訂正） | 移行節を書き直し: 1 周期分の再 converge 1 回を仕様として認める。旧 stamp の昇格はしない |
| F6 | hold 時の fleet metric 保持は事実誤認。gate 系列が途中 publish で消える | 採用（文書訂正 + gate 引継ぎ） | fleet 系列は従来どおり出さない（ApplyStale の重複を避ける）と明記。gate 系列は verdict 確定まで前周期の値を publish に付ける |
| F7 | 開始前無効化なら成功 2 フィールドで足りる | 部分採用 | 無効化遷移は F3 で採用。フィールド削減は診断・runbook 価値で不採用。却下理由の誤りを訂正 |

## Review 2（実装 diff、adversarial, codex — `docs/adr/0009-review-diff.md`）

| # | 所見 | 採否 | 反映 |
|---|---|---|---|
| D1 | `verified_sha` / `sha` の部分一致で未検証応答が pass | 採用 | status 行を token 解析、キー全体一致、40 hex 全体一致、重複キーで SHA 破棄。ハーネスに 3 反例 |
| D2 | reader が末尾改行なし・重複キー・`09` を扱えず、破損状態で up_to_date または abort | 採用 | `read ... || [[ -n $k ]]`、重複/未知キーで記録無効化、epoch は十進 12 桁以内。ハーネスに 2 反例 |
| D3 | 状態保存失敗が status 行の前に終了 | 採用 | `write_state` を各段明示検査に変え、失敗は `status=state_write_fail`（exit 1）。orchestrator は hold。ハーネスに mktemp 失敗 |
| D4 | publish の `cp && mv` 分離でコピー失敗時に公開ファイルを壊す | 採用（D7 の形で） | 前周期 gate 行は tmp_out 先頭に入れ、verdict 確定時に置換。publish は `cp && mv` に復元、失敗は前ファイル保持 |
| D5 | hosts.json 検証が空ファイル・文字列 canary・重複 host を通す | 採用 | `jq -s` で文書数 1、canary は boolean のみ、host / label 重複を拒否、処理 canary 数と予定数を照合。ハーネスに 3 反例 |
| D6 | gate 引継ぎテストが実装を消しても PASS、陳腐化した pass が残る | 採用 | 2 台目 canary を 3 秒遅延させ途中 publish を実観測するテスト。`auto_mitamae_canary_gate_timestamp_seconds` を新設し `AutoMitamaeCanaryGateStale`（15 分）で陳腐化を検出 |
| D7 | gate 引継ぎは tmp_out に持てば小さい | 採用 | 上記 D4 |
| D8 | 「sshd が env を落とす」は設定上の裏付けなし | 採用 | `SSH_CONNECTION` が設定されていれば override を unset（forced-command を含む全 ssh セッション）。コメントを訂正。ハーネスに ssh セッション模擬 |
