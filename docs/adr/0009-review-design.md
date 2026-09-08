# ADR 0009 設計レビュー（adversarial, codex）

## 所見

対象は Proposed の ADR 0009。現行コードの静的読解と提案状態機械の反例を区別して記す。以下の反例は本番実測ではない。観点 1 は F5〜F7 と末尾、観点 2 は F1〜F6、観点 3 は F7、観点 4 は F5 と確認表で扱う。

### F1. canary 0 台と設定の再読込を閉じない gate は未検証 SHA を通す

- 深刻度: high
- 根拠: ADR 0009「orchestrator」の全 canary pass 条件（87 行）には非空条件がない。`cookbooks/auto-mitamae-orchestrator/files/hosts.schema.json:9` で canary は必須でなく、現行 `cookbooks/auto-mitamae-orchestrator/files/orchestrator.sh:193` は成功側に初期化し、212 行の canary 列挙が空でも 233 行の fleet へ進む。全エントリで canary を省略した正しい JSON が反例になる。さらに 212 行と 236 行は hosts.json を別々に読むため、両 phase は同じ設定世代を保証しない。設定ファイルは `cookbooks/auto-mitamae-orchestrator/default.rb:117` が apply 中にも更新する。
- 提案: flock 取得後に hosts.json を一度だけ読み、JSON・必須属性・canary が 1 台以上であることを検証して、そのスナップショットから両 phase を作る。設定変更は次周期に採用する。jq の失敗を process substitution に隠さず検査する。gate は初期値を hold とし、予定した全 canary の明示的 pass を確認して初めて開く。表にない status、`success` の SHA 欠落・不一致も hold/fail と明記する。0 台、JSON 破損、phase 間の canary 変更、複数台の pass/hold/fail 全順序を回帰ケースに追加する。

### F2. SHA だけの成功実績は未適用 role を検証済みにする

- 深刻度: high
- 根拠: ADR 0009「runner」の 5 フィールド（37〜41 行）に role がなく、抑制条件にも role 一致がない。`cookbooks/auto-mitamae-target/files/mitamae-runner.sh:68` は要求ごとに role を受け取り、85〜86 行の状態はホスト共通である。同一ホストで SHA S / role R1 の成功後、hosts.json の role を R2 に変更すると、同じ S・窓内・drift=0・直近成功で 4 条件が成立する。R2 を一度も実行せず `verified_sha=S` が返り、そのホストが canary なら gate は pass する。role パスは Git SHA とは独立した入力である。
- 提案: 成功証跡を少なくとも `(expected_sha, role)` に結び付け、role 変更時に無効化する。複数 role を同一ホストへ適用する運用なら、ホスト単位の lock は維持しつつ role ごとの証跡を保存する。単一 role 制約を採るなら hosts.json のホスト重複を拒否する。role を交互に実行するたびに共通証跡を上書きする方式は、毎周期 converge を発生させるため採用しない。

### F3. 結果の原子的保存だけでは中断した試行を記録できない

- 深刻度: high
- 根拠: ADR 0009「runner」（58〜60 行）は成功・失敗の終了時にだけ状態を書き、試行開始前の遷移を定義していない。例えば S の成功時刻を 1000、interval+jitter を 3600 とする。時刻 4700 の定期 reconcile が設定を一部変更した後、結果保存前にプロセスを終了させ、時計を 4500 に戻す。古い成功時刻 1000 は未来ではなく、4 条件が全て成立する。中断した適用を再試行せず canary は pass する。時計を使わない反例もある。A 成功→B の部分適用中に終了→A の成功窓内に origin/main を A に戻すと、B から A への `HEAD..origin/main` は 0、旧成功 A がそのまま通る（祖先方向の drift=0 は `cookbooks/auto-mitamae-target/files/mitamae-runner.sh:127` に明記）。tmp+mv は破れたファイルを防ぐが、旧成功を残すこの経路は防がない。
- 提案: 副作用を起こす apply の前に、lock 内で成功証跡を確実に無効化する。5 フィールド案を維持するなら `in_progress` を追加して開始時に保存し、success 以外を抑制不可にする。無効化や状態保存に失敗した場合の応答も明記し、未保存の証跡による `up_to_date` を禁止する。同一ファイルシステム上の一意 tmp と rename を使い、状態の読取・判定・無効化・適用・保存を同じ flock の区間に置く。時計巻き戻し、apply 中の強制終了、rename 失敗を検証に加える。

### F4. 300 秒の SSH timeout はリモート lock の解放を保証しない

- 深刻度: medium
- 根拠: `cookbooks/auto-mitamae-orchestrator/files/orchestrator.sh:146` の timeout 対象はローカル ssh である。runner は `cookbooks/auto-mitamae-target/files/mitamae-runner.sh:90` で FD 9 を開き、176 行で期限なしの mitamae を実行する。SSH 切断後も終了しない mitamae、または FD 9 を継承して生存する子プロセスを置くと、次周期は `lock_held` を返し続ける。ADR の新 gate はその間 fleet 全体を hold する。300 秒でリモートプロセス群を止める契約がないため「次 cron で再試行」は converge の再開保証ではない。実際の fleet 上でこの残留が起きているかは未確認。
- 提案: リモート側にも apply の期限とプロセス群の終了・回収を定義し、処理の残留中に別 apply が始まらない lock の寿命を設計する。lock ファイルの削除で回復させない。終了しない子・FD 継承・SSH 切断を模擬し、期限後に次周期が再び apply できることを確かめる。hold アラートにはリモート runner/mitamae の残留を確認する復旧手順を付ける。これは到達不能を理由に gate を開ける提案ではない。

### F5. 自己更新の最初の成功は新状態を書かず、追加 converge を生む

- 深刻度: medium
- 根拠: ADR 0009「移行」（67〜70 行）は変更コミットの成功で新状態が書かれ「追加の fleet 同時 converge は発生しない」とする。しかし `cookbooks/auto-mitamae-target/default.rb:126` は apply の途中で次回用 runner を install するだけで、呼び出し中の旧 runner を新 runner として再実行しない。旧 runner が既に解釈した成功分岐は `cookbooks/auto-mitamae-target/files/mitamae-runner.sh:176`〜181 行の旧 stamp 更新である。したがって初回成功後の新形式状態の生成は保証されず、次周期の新 runner は状態欠落として同じ SHA を再 converge する。自己更新前の apply 失敗で HEAD だけ更新先 SHA に進み、旧 runner が窓内の `up_to_date` を返す canary は、新 orchestrator から hold され、旧窓の期限到来まで更新が進まない。成功した apply だけを模擬した新 runner のテストではこの移行経路を検証できない。
- 提案: 旧スクリプト→新スクリプトの自己更新をテスト対象にし、初回更新を実行する主体と証跡生成の主体を明記する。追加 converge を避けるなら、まず旧 throttle を維持しつつ成功時に新証跡も書く互換 runner を配布し、その配布を確認してから別コミットで新しい抑制条件と gate を有効化する。その別コミットを適用する互換 runner が新証跡を残す。別案は二度目の converge を仕様として認め、移行時だけ段階的に実施すること。現状の「追加なし」という負荷抑制の保証は削除する。未検証の旧時刻 stamp を新証跡へ昇格させてはならない。

### F6. hold 時のメトリクス保持は現行動作ではなく、新規実装が必要

- 深刻度: medium
- 根拠: ADR 0009「orchestrator」（85 行）の「fleet 側の per-host metric は前周期の値を保持（従来の abort と同じ）」は事実と異なる。`cookbooks/auto-mitamae-orchestrator/files/orchestrator.sh:74`〜97 行は空の tmp にヘッダーを作り、107〜108 行の publish が出力全体を置換する。199 行の最初の canary publish で未処理 fleet の行は消え、225 行の abort でも復元しない。`cookbooks/lxc-monitoring/files/alerts/auto-mitamae.yml:24` は存在する timestamp の古さしか検査せず、canary の系列が残るため 172 行の全体 absent 検知も fleet 個別の消失を拾わない。また新 gate 指標を全 canary 終了後にしか出さない実装では、途中 publish で系列が消えた間に scrape と alert 評価が走ると、hold の `for: 30m` がリセットされる。
- 提案: 前周期のホスト別値を読み込み、処理したホストだけ置換して各 publish に未処理ホストの値も含める。削除ホストは F1 の設定スナップショットに従って除く。gate 指標は全 publish で保持し、完了した判定の時刻も公開する。hold 継続だけでなく、gate 判定が更新されない timeout も監視する。2 台目以降の canary で hold/fail、全周期 timeout、途中 scrape を含むケースで per-host series と alert の継続性を確認する。

### F7. 開始前に無効化する成功証跡なら 5 フィールドは不要

- 深刻度: medium
- 根拠: ADR 0009「Rejected alternatives」（123〜124 行）は「成功 SHA だけ追加」では同一 SHA の定期失敗を抑制するとする。時計・interval・jitter が不変なら、定期適用に入った時点で `now >= last_success_epoch + interval + jitter` である。失敗時に stamp を更新しない現行 `cookbooks/auto-mitamae-target/files/mitamae-runner.sh:169`〜185 行では、次周期も窓外のままであり、この却下理由の通常時の反例は成立しない。巻き戻しや中断への対策は必要だが、直近試行の SHA・時刻を常時保存する必然性はない。
- 提案: 最小案は `success_sha + success_epoch` の証跡を持ち、apply 開始前に無効化し、成功終了時だけ tmp+rename で再発行する。F2 の role 一致も証跡キーに含める。最後の成功履歴が診断用に必要なら、抑制の証跡と別目的として扱う。orchestrator の verified_sha 判定・閉じた gate・hold 監視は ADR 案を使う。これで検証 1 は B 失敗後に証跡がないので再試行、検証 2 は定期失敗後も証跡がないので再試行、検証 3 は明示的 pass 以外に fleet SSH を行わず、検証 4 は成功した同じ SHA/role の窓内では呼出数不変となる。窓外かどうかに依存せず失敗・中断に対処でき、F3 の開始遷移も同時に解決する。

観点 2 の指定順での確認結果:

| 攻撃入力 | 判定・根拠 |
|---|---|
| クロック | 未来時刻を成功実績なしにする仕様は妥当。ただし過去の成功時刻より後への巻き戻しと未記録の試行中断は F3。永続的な時計異常下で毎回 converge する負荷は窓だけでは抑制できない。 |
| 部分書き込み | 同一 FS の tmp+rename は部分ファイルの露出を防ぐ。開始時無効化と保存失敗時の規約は別途必要（F3）。数字・SHA の形式検査に加え、重複キー、未知 status、整数範囲、フィールド整合を検査し、不正な状態を shell として source しない。 |
| flock | 現行のホスト単位排他は runner 同士の競合を防ぐ。読取から保存まで維持すること。残留 FD の liveness は F4。手動の直接 mitamae はこの lock を取得しない（runner のヘッダー 47〜48 行にも bypass と明記）。 |
| 旧/新 runner 混在 | 新 gate の旧 `up_to_date` 拒否は妥当。新 runner の自己更新に伴う追加適用は F5。旧 orchestrator が残る間は transient を通すため、新 gate の保証開始点を移行手順で明記する。 |
| 複数 canary | 非空かつ全台 pass、fail 優先という集約は妥当。0 台・設定世代は F1、途中 publish と timeout は F6。 |
| `git_fetch_fail` | 現行 runner 100〜103 行で checkout 前に終了する。gate の fail は妥当。apply を開始していないので成功証跡を破棄する必要はない。失敗を誤って success/up_to_date と分類しない回帰ケースを追加する。 |
| hosts.json の変更 | canary 集合のスナップショットは F1、同一 SHA での role 変更は F2。新ホストに成功状態がなければ converge する仕様は妥当。 |
| orchestrator の 300s timeout | 1 ホストの SSH に対する上限で、周期全体ではない（F4）。外側 cron は 900 秒（orchestrator/default.rb:214）。複数の遅い canary が合計 900 秒を超えると gate 集約に到達せず、繰り返し fleet を未処理にする。未完了周期の監視が必要（F6）。 |
| cron の重複起動 | orchestrator.sh:45〜49 の非ブロック flock が二重起動を抑止する。継続中の周期が 5 分を超えれば次 cron は skip するため、ADR の「次周期（5 分）」は最短の再起動機会であり回復期限ではない。lock パスを移行で変えないこと。 |

観点 4 の維持事項:

| 維持事項 | 判定 |
|---|---|
| 負荷抑制・jitter | 定常時の 4 条件と role 由来 jitter は維持される。移行時の追加 converge は抵触（F5）、複数 role の共通証跡は連続 converge を招く（F2）。 |
| forced-command・env・`restrict` | コマンド構文と authorized_keys を変更する提案ではないため直接の抵触なし（target/default.rb:166、runner.sh:64）。テスト override を追加する際も SSH のコマンド文字列から設定を受け取らない。実機 sshd の AcceptEnv 等による env 遮断は未確認。`restrict` 単独を env 遮断の証明にしてはならない。 |
| 呼び出し側 OS 選択 | 抵触なし。ADR の変更対象は Linux runner/orchestrator と監視・テストであり、cookbook 内への OS 分岐追加を要求していない。 |
| 薄い LXC エントリ | 抵触なし。entry recipe に状態機械を移す提案ではない。 |
| IAM 境界 | 抵触なし。runner.sh:59 の `AWS_PROFILE=pve-bootstrap-ssm` と forced-command の維持で実現でき、admin 資格情報や新しい AWS 権限は不要。 |

## 前提の反証で見つかった事実誤認

- **「従来の abort は fleet の前周期 metric を保持」**（ADR 0009:85）は誤り。新しい tmp による全体置換で消える（orchestrator.sh:74〜108、199、225）。F6。
- **「変更コミットの成功で新形式状態が書かれ、追加 converge なし」**（ADR 0009:68〜69）は自己更新の実行主体を取り違えている。旧 runner は旧 stamp を書く（runner.sh:176〜181、target/default.rb:126〜129）。F5。
- **「同一 SHA の定期 reconcile 失敗後、前回成功の窓内なので抑制される」**という一般化（ADR 0009:123〜124）は、時計等が不変の通常経路では成立しない。定期適用を開始できたこと自体が窓外の証拠である。F7。
- **「B は再試行されない」**（ADR 0009:22）は期間の限定が欠ける。A の stamp に基づく窓内では再試行されず、窓の期限後には runner.sh:169〜176 が converge を実行する。恒久停止と窓内の誤抑制を区別する。

Context の A 成功→B 失敗→窓内の同じ B が up_to_date、および transient canary を通す分岐自体は現行コードと一致する（runner.sh:135、169〜185、orchestrator.sh:200〜210）。
