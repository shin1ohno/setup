# ADR 0009 実装 diff レビュー（adversarial, codex）

## 所見

対象は `origin/main..fix/auto-mitamae-per-sha-state`（`daede30`、`1906834`）。行番号は変更後ファイル。観点 1 は D1〜D6・D8、観点 2 は D1〜D6、観点 3 は D7、観点 4 は D5・D8 と末尾の維持事項で扱う。追加検証は本番スクリプトを変更せず、既存ハーネスのローカル Git・mitamae/SSH stub に異常入力を追加した。実機への適用は行っていない。

### D1. verified_sha の部分一致で未検証応答が gate を通る

- 深刻度: high
- 根拠: `cookbooks/auto-mitamae-orchestrator/files/orchestrator.sh:217`、`:220`、`:221`、`:270`。`verified_sha` の左境界も SHA の右境界も検査しない。期待 SHA を S とすると、`status=up_to_date not_verified_sha=S` だけの応答で **gate=pass、fleet SSH=1** を再現した。`status=success sha=Sz`（末尾に非 hex の z）でも同じ結果になる。`sha` の左境界だけを直した実装では、ADR の「証跡の欠落・不一致は hold」（ADR 0009:93）が成立しない。SSH 出力は stderr も合流し、各フィールドを別々に最初の一致から拾うため、一つの正当な status 行である保証もない。現行 runner の正常出力はこの反例の文字列を生成しない。これは異常応答を注入した場合の gate 入力検証の欠陥であり、本番の誤展開を観測した報告ではない。
- 提案: stdout の単一 status 行を空白区切りの key/value として解析し、キー完全一致・重複拒否・SHA 全体の `^[a-f0-9]{40}$` を確認する。stderr は分離する。未知キーの接尾辞、非 hex 接尾辞、複数 status 行、行をまたぐ合成を回帰に加え、不正応答は hold にする。旧 runner の正当な success は引き続き許容する。

### D2. 「破損状態は converge」の保証を reader が満たさない

- 深刻度: medium
- 根拠: `cookbooks/auto-mitamae-target/files/mitamae-runner.sh:199`、`:210`、`:220`、`:241`。正常な成功状態に末尾改行なしの `last_attempt_status=mitamae_fail` を追加すると、`read` が最後の行を処理せず **up_to_date / exit 0** となる。重複キーも拒否せず最後に処理した値を採用する。`last_attempt_sha` と `last_attempt_epoch` を削除した状態も up_to_date となった。前者は sanitize するが判定に使わず、後者は読んでいない。さらに `last_success_epoch=09` は数字の正規表現を通り、Bash の八進数解釈で算術評価が失敗し、`:251` の `reconcile_due: unbound variable` で **status なし / exit 1** となった。欠落・破損は成功実績なしとする ADR 0009:69 と矛盾する。
- 提案: 必須キーを各 1 回だけ許す reader にし、末尾改行なしの行も処理した上で、欠落・重複・フィールド間の矛盾を状態全体の無効化に結び付ける。時刻は十進数へ明示変換する前に桁数・範囲を検証し、巨大整数のオーバーフローも拒否する。`last_attempt_status=success` なら attempt と success の SHA・時刻整合を確認する。

### D3. 状態保存に失敗すると status 行より前に終了する

- 深刻度: medium
- 根拠: `cookbooks/auto-mitamae-target/files/mitamae-runner.sh:125`、`:128`、`:265`、`:272`、`:283`、`:289`。窓外の reconcile で `mktemp` または `mv` を exit 1 の stub に置換すると、いずれも **status 空 / exit 1** となった。runner の `set -e` / `inherit_errexit` はここで有効であり、保存失敗を表す応答がない。開始保存に失敗すれば apply に進まない点は安全だが、orchestrator はローカル記録障害を ssh_unreachable に変換して hold する。終了時の保存失敗も同じ構造で、apply 結果が応答に出ない。`:29` の「error path でも status を出す」という説明は新設経路で成立しない。
- 提案: write_state 内の mktemp・printf・mv をそれぞれ明示的に検査し、失敗時は一時ファイルを掃除して専用の非ゼロ結果を返す。呼出側は `state_write_fail` 等を必ず出し、verified_sha は出さない。関数を `if ! write_state` に入れるだけでは内部の errexit が無効になるため、各操作の明示検査を省かない。開始失敗時の「mitamae 呼出ゼロ」と、終了保存失敗後の再試行を検証する。

### D4. publish から cp 成功条件を外し、失敗時に正常なメトリクスを壊す

- 深刻度: medium
- 根拠: `cookbooks/auto-mitamae-orchestrator/files/orchestrator.sh:48`、`:157`〜`:161`。旧実装の `cp ... && mv ...` が独立した cp と mv に変わった。orchestrator に errexit はない。cp を失敗させ、前周期 gate=pass の状態で今回の canary を lock_held にすると、cp 後の echo が `.pub` を作り、mv が公開ファイルを **`auto_mitamae_canary_gate{result="pass"} 1` の 1 行だけ**へ置換したことを、最後の mv の直前に採取して確認した。rename の原子性は内容の完全性を保証しない。今回追加の gate 引継ぎが既存のコピー失敗ガードを壊している。
- 提案: cp と gate 追記の両方に成功してから mv する。失敗時は既存公開ファイルを保ち、周期を非ゼロ終了させる。mktemp 失敗も SSH 前に検査し、publish / 最終 mv の失敗を呼出側で処理する。現在は mktemp 失敗後も空の tmp_out のまま処理を進める。容量不足・コピー失敗・rename 失敗で前回ファイルが保たれることを検証する。

### D5. hosts.json 検証が空ファイル・canary の型・同一 host を拒否しない

- 深刻度: medium
- 根拠: `cookbooks/auto-mitamae-orchestrator/files/orchestrator.sh:99`〜`:107`、`:294`、`:335`。空ファイルは jq が入力を一つも評価せず exit 0 になり、**SSH 0 件、gate=pass、exit 0** を再現した。canary が boolean true のホストを 1 台残し、別の canary を文字列 `"true"` にすると後者は fleet phase に入り、そのホストの mitamae_fail にもかかわらず **gate=pass、後続 fleet 実行**となった。さらに同一 host を別 role の 2 エントリにした入力も通り、同じ host が周期内で 2 回呼ばれた。F2 採用表の「1 ホスト 1 role」は検証されず、runner の単一証跡を相互に上書きして毎周期 converge する。ハーネス `:157`〜`:162` 自体も role 往復の再適用を確認している。
- 提案: jq の slurp で入力 JSON 文書がちょうど 1 個であることを確認する。canary は省略か boolean に限定し、host と metric label の重複を拒否する。host/user/role/label の非空・書式も既存 hosts.schema.json と揃える。両 phase の列挙結果を先に生成して終了値を確認し、process substitution の失敗後に初期値 pass が残らないよう予定 canary 数と処理数を照合する。

### D6. gate 引継ぎテストは実装を削除しても PASS する

- 深刻度: medium
- 根拠: `cookbooks/auto-mitamae-target/test/run-state-scenarios.sh:271`〜`:273` は「次周期の途中 publish」を述べるが、実際は run_orch の終了を待ち、最終ファイルの行数だけを確認する。scratch の orchestrator コピーで prev_gate_line の読取・追記を丸ごと削除し、旧 `cp && mv` に戻しても **78 passed, 0 failed** だった。`1906834` の「gate carry-over をハーネスで検証」という主張をこのテストは裏付けない。
- 提案: 2 台目の canary 応答を制御して、1 台目の publish 直後のファイルを採取し、前回 hold 系列が 1 本存在することを検査する。前回 pass/今回未完了も検査する。現実装は gate に判定時刻・SHA を付けず、`:154` の前回値をそのまま引き継ぐため、毎回途中で周期が終了すると過去の pass が残り続ける。これは今回の引継ぎで見えなくなる未完了状態である。F6 の未完了周期監視を実装するなら、判定完了時刻を独立 metric にし、その古さを監視する。`CanaryHeld` だけでは過去 pass の陳腐化を検出しない。実機での発生は未確認。

### D7. gate 引継ぎを蓄積ファイルに持たせれば小さくできる

- 深刻度: low
- 根拠: `cookbooks/auto-mitamae-orchestrator/files/orchestrator.sh:154`〜`:161`、`:296`〜`:313`。現在は「蓄積ファイルに gate があるか」を外部変数 gate_verdict と対応させ、publish ごとに前回値を追記する。scratch の代替では前回 gate を最初に tmp_out へ 1 回追加し、判定確定時に `sed -i '/^auto_mitamae_canary_gate{/d' "$tmp_out"` で除いて今回値を追加した。publish は旧 `cp && mv` に戻せる。実コード比較で **3 行追加・8 行削除**、同じハーネスで **78 passed, 0 failed** を確認した。
- 提案: この形を基に D4 の明示的エラー処理を加える。runner の診断用 6 フィールドは維持でき、F7 で不採用となった診断削減を再提案する必要はない。78 assertions の一致は確認済みだが、異常時の等価性は D6 の追加検証が必要であり未確認。

### D8. テスト用 env が本番で届かないという断定に設定上の裏付けがない

- 深刻度: low
- 根拠: `cookbooks/auto-mitamae-target/files/mitamae-runner.sh:85`〜`:92` は新しいパス override を無条件に読む一方、「sshd が env を落とす・restrict なので本番は常に既定値」と述べる。`cookbooks/auto-mitamae-target/default.rb:166` が設定するのは command/restrict/from であり、AcceptEnv / PermitUserEnvironment の制約ではない。restrict は環境変数全般を禁止する指定ではない。repo の検索で Linux 対象のこれらの sshd 設定は見つからず、実機の有効設定は未確認。したがって漏洩が起きたとは断定しないが、本番既定値の保証は証明されていない。
- 提案: コメントを確認済みの範囲へ限定し、対象 sshd の有効 AcceptEnv / PermitUserEnvironment を配備検証に含める。新しいパス override は forced-command の本番入口で既定値に固定し、テストは別のローカル入口で注入する。広い AcceptEnv を持つ fixture でも、SSH から setup_dir / lock_file / state_dir を変更できないことを確認する。

維持事項（観点 4）の残りは抵触なし — role 由来の cksum jitter と reconcile 窓の式は runner:248〜250 で維持される。D5 の重複 host はその前提を破る例外である。移行時の追加 converge は ADR 0009:77〜85 が認めており、F5 を再掲しない。forced-command の入力正規表現（runner:79）と鍵の command/restrict/from は維持。AWS_PROFILE は runner:74 で pve-bootstrap-ssm に固定され、新規 IAM 権限・admin 資格情報は追加されない。呼出側 OS 選択・薄い LXC エントリは対象差分に変更がない。

観点 2 の制御フロー補足: orchestrator:48 は `set -uo pipefail` であり、`:265` / `:270` の `[[ ]] && verdict=pass` が偽でも abort しない。runner の今回追加箇所に「関数末尾の偽 `[[ ]] &&`」による終了はない。ハーネスは両スクリプトを別 Bash プロセスとして起動するため、親関数の条件文によって runner の errexit が解除される経路ではない。hold の exit 0 は cron の再実行を妨げない（orchestrator/default.rb:214 は 5 分ごとの無条件起動）。ただし MAILTO は空、全周期 timeout は 900 秒なので、exit 0 自体は再試行期限・完了を保証しない。F4 のリモート残留は TODO.md に記録済みであり、同じ所見を新規計上しない。

## 設計レビュー採用項目の実装確認

| 項目 | 判定 |
|---|---|
| F1 | 閉じていない — 一度の読取と同一 snapshot の利用は orchestrator:99・:294・:335 に実装。空ファイルは検証を素通りし 0 canary で pass（D5）。 |
| F2 | 閉じていない — role 一致は runner:242 とハーネス:157〜162 で確認。採用の前提「1 ホスト 1 role」を重複 host 拒否で保証していないため連続 converge が残る（D5）。 |
| F3 | 閉じている（中断時の旧証跡無効化） — runner:265 が flock 内・mitamae 実行前に in_progress を保存し、ハーネス:168〜174 の kill 後再実行が PASS。開始保存失敗時も apply には進まない。ただし保存失敗の応答規約は未実装（D3）。 |
| F6 | 閉じていない — 採用範囲は「fleet 保持」を撤回した文書訂正と gate 引継ぎ。ADR:103 は訂正済みだが orchestrator:250〜251 は今も fleet の前回状態を保持すると記す。通常 publish の gate 引継ぎは実装済みだがコピー失敗で系列を壊し（D4）、テストはその機能を検証しない（D6）。設計レビューが求めた判定完了時刻・未完了監視は今回も存在しない。 |

## ハーネス実行結果

`set -o pipefail` の下で `bash cookbooks/auto-mitamae-target/test/run-state-scenarios.sh | tail -1` を実行し、終了値 0 を確認した。

```text
auto-mitamae state scenarios: 78 passed, 0 failed (mitamae calls total: 13)
```

ノードの `scripts/test.sh` は no-op、終了値 0。`scripts/lint.sh` も終了値 0（既存の空 wiki index に関する注記 2 件が各 wiki に出る）。D1〜D5 の追加反例、D6 の機能削除実験、D7 の簡素化案はこの 78 assertions とは別に確認した。実装ファイルと既存テストは編集していない。
