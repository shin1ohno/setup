# ADR 0009: auto-mitamae — 適用成功状態を SHA 単位で管理し、canary gate は検証済み SHA だけ通す

**Status**: Proposed (2026-09-07) — supersedes the time-only stamp of ADR 0006 (ADR 0006 の二段階カデンス自体は維持)

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
drift==0 になり、A の成功時刻で抑制条件が成立する。B は再試行されない。

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
last_success_epoch=<int>
last_attempt_sha=<40hex>
last_attempt_status=success|mitamae_fail
last_attempt_epoch=<int>
```

抑制（`status=up_to_date` で mitamae を呼ばない）の条件は次の **全て** が成立する場合に限る:

1. `drift == 0`（origin/main に新規コミットがない）
2. `last_success_sha == expected_sha`（この SHA で成功した実績がある）
3. `last_attempt_status == success`（直近の試行が失敗していない）
4. `now < last_success_epoch + RECONCILE_INTERVAL_SEC + host_jitter`（ADR 0006 の窓、不変）

1 つでも欠ければ converge する。結果として:

- A 成功 → B 失敗: 次周期は 2 が不成立 → B を再試行する。
- 同一 SHA の定期 reconcile が失敗: 3 が不成立 → 次周期に再試行する（stamp は失敗時に更新しない、
  という ADR 0006 の方針を「直近試行」フィールドで明示化）。
- 検証済み同一 SHA: 1〜4 成立 → 抑制（負荷抑制・jitter は不変）。

成功時は 5 フィールド全部を更新し、失敗時は `last_attempt_*` の 3 フィールドだけを更新する
（`last_success_*` は最後に成功した SHA を保持し続ける）。状態ファイルの sanitize は ADR 0006 と
同じ方針: 欠落・非数値・未来時刻・40hex でない SHA は「成功実績なし」と読み、converge に倒す。

status 行には `verified_sha=<sha>` を **追加**する（既存フィールドの後ろ、`ts=` の前）。
`up_to_date` のとき値は expected_sha と等しい。`success` のときも同じ値を載せ、orchestrator は
「この応答は expected_sha の成功実績に裏打ちされている」と機械的に読める。旧 orchestrator の
`grep -oE 'sha=[a-f0-9]+' | head -1` は先に現れる `sha=` を取るので互換。

移行: 旧 `last-converge.epoch` は読まない（SHA が不明なので「成功実績なし」と等価）。この変更自体が
新規コミットとして着弾するので、全ホストは drift>0 で一度 converge し、その成功で新形式の状態が
書かれる。追加の fleet 同時 converge は発生しない（今日のコミット着弾時と同じ挙動）。成功時に旧
stamp を削除する。

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
`hold` が 30 分続いたら warning を出す `AutoMitamaeCanaryHeld` を追加する。fleet 側の per-host
metric は hold 中も前周期の値を保持する（従来の abort と同じ）。

複数 canary がある場合は全 canary が pass のときだけ fleet へ進む。fail が 1 台でもあれば fail、
そうでなく hold が 1 台でもあれば hold。

### 検証（回帰テスト）

`cookbooks/auto-mitamae-target/test/run-state-scenarios.sh` が hermetic な一時ディレクトリに
ローカル origin・clone・成功/失敗を切り替えられる mitamae 代替・`ssh` 代替を作り、本番スクリプトを
**そのまま**（パスは `AUTO_MITAMAE_*` env override で差し替え。forced-command 経路には sshd が env
を落とすので届かない、ADR 0006 と同じ性質）実行して次を PASS させる:

1. A 成功 → B 失敗 → 同じ B を再試行する（`up_to_date` を返さない）→ B 成功 → 以後 `up_to_date`
2. 同一 SHA の定期再適用が失敗 → 次周期で再試行する
3. canary が `ssh_unreachable` / `lock_held` / `sha_mismatch` / `verified_sha` 欠落の `up_to_date` /
   `mitamae_fail` のとき fleet ホストへ ssh しない。`success` / 検証済み `up_to_date` のときだけ ssh する
4. 検証済み同一 SHA では mitamae 呼出回数が増えない（負荷抑制の維持）

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
- 状態ファイルは 5 行の平文。`jq` 等の依存を runner に増やさない。
- Rollback: 2 スクリプトの revert。状態ファイルは残っても無害。

## Rejected alternatives

- **失敗時に HEAD を旧 SHA へ戻す**（apply 失敗を drift>0 に見せかける）: 次周期の `git checkout`
  で再び B に進むだけで、途中で HEAD が揺れる。CT103 不変条件（host は常に expected_sha を追従）
  に反する。却下。
- **stamp に成功 SHA だけ追加**（直近試行の成否を持たない）: 同一 SHA の reconcile 失敗（シナリオ 2）
  で、前回成功の時刻が窓内なら抑制されてしまう。「直近試行」を分けて持つ必要がある。却下。
- **orchestrator 側だけで直す**（canary が `up_to_date` のときは常に hold）: 定常状態で全周期 hold
  になり fleet の reconcile が止まる。runner が検証済みであることを応答に載せる方が単純。却下。
- **JSON 状態ファイル**: runner に `jq` 依存を追加する。`key=value` の 5 行で十分。却下。
- **canary の transient を N 回まで許容して fleet へ進む**: 「何も検証していない SHA を配らない」
  という不変条件に例外を作る。hold の可視化（metric + alert）で運用上の停止は見えるので不要。却下。
