# ADR 0011 / 0012 設計レビュー（adversarial, codex）

対象は両 ADR と指定された最小実装。根拠の行番号はこの worktree のソースを指す。high は中核の検査・完了判定を破るもの、medium は契約の欠落・運用上の失敗を指す。反例は静的読解による入力例であり、設定を変更しての実行結果ではない。

## ADR 0011 所見

### F1. 正規表現は node-exporter の全 static target を列挙しない

- 深刻度: **high**（前提反証・偽陰性）。
- 根拠: `bin/check-host-configs:39` は無引用の `job_name: node-*` と直後の改行だけを認識し、`:40` と `:41` は最初の IPv4 target と最初の host label しか取らない。既存 job の targets に廃止 IP `.72:9100` を二つ目として足しても、その target は検査されない。`job_name: "node-retired"` の追加も検査から消える。現在の 19 個の node job が拾えることは、YAML の合法な別表記・複数 static_configs を網羅する根拠にならない。非 node の static job も存在する（`cookbooks/lxc-monitoring/files/prometheus.yml:226` 以降）が、それは別 exporter であり、全部を node-exporter として検査するのも誤り。
- 提案: Ruby 標準の YAML パーサーで scrape_configs → static_configs → targets を全件走査する。node-exporter の対象集合を明示し、対象内の未対応構造は FAIL にする。最初の 1 件だけを採る処理を廃止する。これだけで静的 job のまま既存の検証 (1)〜(4) を強化できる。

### F2. DNS target は宛先を読まずラベルだけで承認される

- 深刻度: **high**（失敗モード・監視先の偽陰性）。
- 根拠: `bin/check-host-configs:63`・`:73` は IPv4 を抽出できない job をすべて DNS 扱いにし、`:74` は label の存在だけで合格させる。`node-nrt-router` の target（`cookbooks/lxc-monitoring/files/prometheus.yml:198`）を `wrong.example:9999` に変えても `host: nrt-router` と policy が残れば合格する。target 自体の削除でも同じである。既存 IP job を残したまま任意 DNS を指す job に既存 label を付けても、hosts.json 側の欠落検査に引っ掛からない。DNS alias は名前解決を行わずに許可され、実際の宛先との対応を証明しない。
- 提案: target の構文・ポートを必須検証し、「解析不能」と「DNS」を分ける。DNS 名はオフラインの明示的な対応表で検証し、現在の nrt-router には既存契約の FQDN を使う。CI で DNS 解決や AWS 読み出しを追加しない。home-monitor が EC2/DNS を所有する IAM 境界は維持する。

### F3. 理由付き例外と別名の契約が実装されていない

- 深刻度: **medium**（前提反証・policy の抜け道）。
- 根拠: ADR 0011:42 は理由なし例外を禁止するが、`bin/check-host-configs:58`・`:65`・`:82`〜`:86` は key の有無だけを調べる。値が空文字や null でも除外になる。`prometheus_job_label_aliases`（`config/host-policy.json:6`）は job 名ではなく host label をキーに引く（checker:70）。別名は検査内で変換されるだけで、Prometheus が保存する label は変わらず、ADR 0011:65 の host label 契約維持を保証しない。alias には理由欄も stale 検査もない。さらに apply_only は読み込みと stale 検査だけで、監視欠落を許可しない。unmonitored は監視が復活しても host が残れば stale 扱いされない。
- 提案: 例外を `{reason, ...}` の型付き構造にし、空理由・未知キー・重複分類・効力を失った例外を拒否する。apply_only と unmonitored は意味を一つに整理する。job 名の別名と host label の別名を分離し、label は原則 canonical 値を要求する。別名を許すなら Prometheus 側の変換と利用側の契約をセットで定義する。

### F4. FLEET の抽出漏れと共通部分だけの比較が成功になる

- 深刻度: **medium**（前提反証・偽陰性）。
- 根拠: `bin/check-host-configs:47` は Ruby を評価せず、二重引用符・空白・hash の字面に依存する。例えば es-0 の IP を誤値へ変更しつつ `'ip' => '192.168.1.99'` と単一引用符にすると、その行は検査集合から消える。抽出件数ゼロも FAIL にしない。`:78` は hosts.json に同じ label がない FLEET IP を無条件に無視するため、削除時の古い transport IP も見逃す。実際の消費側は `cookbooks/host-profile/default.rb:93` の `spec["ip"]` であり、Ruby の引用符変更で動作は変わらない。
- 提案: IP を持つ identity subset を小さなデータファイルに分離し、host-profile と checker が同じ値を読む。完全な SSM snapshot 導入までは、少なくとも抽出不能・想定集合の欠落・対応先のない IP を FAIL にする。全 FLEET ホストを自動適用対象にする必要はない。IP を持たない Mac 等は現行の役割のまま扱う。

### F5. snapshot の延期と file_sd の延期を同じ理由にしている

- 深刻度: **medium**（小さい代替・handoff）。
- 根拠: ADR 0011:72 は file_sd 導入まで SSM schema 確認に依存させるが、既存 target を file_sd に移すだけなら上流 schema は不要である。一方、3 表の相互一致だけでは全表が同じ誤 IP に更新された場合を検出できない。ADR の表題「一元化」は今回の実装では達成していない。
- 提案: 今回は既存 static 設定への YAML 構造検査、policy の型検査、FLEET subset の読み出しを小さく直す。これで検証 (1)〜(4) を維持し、生成器なしでも安全に強化できる。版付き snapshot の延期は上流の事実未確認という理由で妥当。file_sd の延期理由は移行範囲と job/host label 互換性の確認コストと明記する。将来 file_sd にしても honor_labels と既存 query の job 依存を確認する。今回の Prometheus 差分は `.72` の削除と `.61/.84/.83` の追加で、honor_labels と canonical host label を保持している。呼び出し側 OS 選択・platform-purity・薄い LXC entry・role 所有は変更なし。SSM/IAM の所有は home-monitor に残り、新権限は不要。既存 lint/reachability を置き換えず追加検査として扱う。

## ADR 0012 所見

### G1. doctor の前置きが正常な初回認証と再適用を遮断する

- 深刻度: **high**（前提反証・初回構築の停止）。
- 根拠: `bin/converge:53` は entry の前に doctor の全 FAIL を終了 3 にする。doctor は常に aws-config.json の固定 profile で STS を実行する（`bin/doctor:72`・`:80`〜`:85`）。一方 ssh-keys は TTY で任意の有効 profile を自動選択する契約（`cookbooks/ssh-keys/default.rb:30`〜`:42`、functions:245）なので、別名の有効 profile しかない Mac でも entry に到達できない。新規ホストの AWS 認証プロンプトにも到達しない。また bootstrap の `/usr/local/bin` 追加は子プロセス内だけ（`cookbooks/awscli/common.rb:34`）。親 shell の PATH に同ディレクトリがなければ、インストール成功後でも doctor:55 が aws 不在と判定し、再実行しても同じ箇所で止まる。
- 提案: wrapper 側で必要な PATH を明示する。doctor の必須条件を entry と同じ認証契約に合わせ、TTY の初回認証は gate へ進める。fleet は既存の限定 profile を固定し、Mac の成功条件を満たすために全ホストへ管理者資格情報を配らない。「FAIL = converge 不可能」という一般化を撤回する。

### G2. sentinel と doctor では必須 gate の失敗を判定できない

- 深刻度: **high**（前提反証・成功の偽陽性）。
- 根拠: ADR 0012:35 と README:23 は必須 gate の未充足を終了 3 とする。しかし `record_gate_event`（functions:106〜108）は tool と reason だけを記録し、gate-report:29 は任意性を見ず全 tool_missing で sentinel を作る。逆に SSM 権限不足は doctor:99 で WARN、gh 未認証も doctor:154 で WARN になる。非 TTY の gate は auth_unavailable を記録して return（functions:231〜234）、block 内 resource を登録せず成功終了でき、sentinel は残らない。user_skip も block があれば無条件に許される（functions:274〜280）ため、「操作者が skip した」事実は「任意機能」の証明にならない。doctor は SSH 秘密鍵そのものの必須チェックも持たず、ADR 0012:44 の「鍵不在を FAIL」は過大な説明である。
- 提案: gate に安定 ID と required/optional を与え、実行単位の機械可読結果で必須 gate の tool_missing / auth_unavailable / user_skip を終了 3 にする。任意 gate の user_skip は成功扱いを維持する。認証可能な STS と各 SSM/KMS 操作の許可を区別し、doctor は補助診断に限定する。機械可読結果を次の段へ送ったまま「必須 gate 判定を実装済み」としない。

### G3. dry-run が未完了の証拠を消して converged と報告する

- 深刻度: **high**（失敗モード・既存ガードレール）。
- 根拠: `bin/converge:62` の `rm -f` は dry-run でも実行される。gate-report の書き込みは execute resource（`:82`〜`:84`）なので dry-run では sentinel を作らない。`--dry-run --skip-doctor` で mitamae が 0 を返せば、前回の sentinel を削除したうえで wrapper:73 は converged と報告する。bootstrap も dry-run なので aws 未導入は解消しない。従って dry-run の 0 は構築完了の証拠ではない。
- 提案: dry-run は sentinel の変更・完了判定を行わず、表示を「計画の検査完了」に分ける。通常適用も既存 sentinel を先に消す方式をやめ、実行 ID 付き結果の原子的な書き込みで新旧を区別する。既存の dry-run による変更防止を wrapper の shell 処理まで貫く。

### G4. 無限再適用はないが gate の対話ループには上限がない

- 深刻度: **medium**（失敗モード・再実行）。
- 根拠: wrapper は bootstrap と entry を各 1 回しか呼ばないため、自動の無限再適用は発生しない。一方 `require_external_auth` は functions:258〜259 の loop を認証成功まで続け、attempts に上限判定がない。`:271` は EOF を空文字に変換して再チェックする。認証を直さず Enter を繰り返す、または TTY の入力が EOF を返し続ける条件では、同じ compile に留まる。tool_missing の早期 return（`:208`〜`:218`）はこの auth_unavailable 側のループを解決しない。
- 提案: EOF は明示的な中断とし、試行上限か明示的 retry 操作を定義する。ADR の「無限再実行はしない」は wrapper の呼出回数の説明に限定する。二つの独立プロセスで工具導入→entry compile とする案は妥当であり、全 gate の only_if 化は不要。G2 の結果出力と G1 の admission 修正を加える方が、resource 群を全面的に converge 時評価へ移すより小さい。

### G5. fleet は wrapper の完了契約に参加していない

- 深刻度: **medium**（失敗モード・SSH 経路・handoff）。
- 根拠: ADR 0012:46〜48 の bootstrap-lxc-creds は資格情報ファイルを置くだけ（`bin/bootstrap-lxc-creds:66`〜`:78`）で awscli を導入しない。role で awscli を include することは、新規 LXC の compile 開始時に binary が存在する証拠ではない。runner:295 は entry を直接呼び、終了 0 だけで success と verified SHA を記録する（`:296`〜`:304`）。sentinel も auth_unavailable も成功判定に入らない。`SSH_CONNECTION` 分岐（runner:93〜95）はテスト用パス override を消すもので、converge を起動せず、sentinel の生成先・判定にも関与しない。
- 提案: 「唯一の入口」を手動 workstation 適用に限定し、fleet には同じ gate 完了条件を適用する独立した移行条件を記す。新規 LXC の初回 bootstrap と未完了時の verified SHA 非更新を検証する。runner の flock、SHA/role 検証、forced-command 制限、SSH 時 override 無効化を保ち、単純に runner を wrapper 呼び出しへ置き換えない。薄い LXC entry と role の単独所有、pve-bootstrap-ssm の IAM 境界は維持する。

### G6. bootstrap は認証 gate を呼ばないが host 変更は行う

- 深刻度: **medium**（前提反証・ガードレールの順序）。
- 根拠: bootstrap:19〜20 → functions:549 → host-profile、および awscli の include 経路に実行される require_external_auth はない。functions 内の gate 呼び出しは helper 定義内であり、bootstrap compile で gate が動くという反証は成立しない。ただし「host 設定なし」（ADR 0012:28、bootstrap:14）は誤りである。functions:560〜569 は setup ディレクトリを作り、awscli/darwin.rb:18 は既存 Homebrew awscli の削除、`:27` は profile ファイル登録を行う。さらに bootstrap は entry より先なので、コンテナで linux.rb を指定した場合も linux.rb:11〜18 の拒否より前にこれらの変更が走る。wrapper:46 は bin/setup 失敗を終了 1 とし、ADR:34〜37 の終了コード一覧にもない。
- 提案: bootstrap の契約を実際の変更範囲に合わせ、entry のホスト種別検証を変更前に行う。必要なら awscli の installer 部分だけを小さな sub-recipe として再利用し、通常設定の所有は元 cookbook/role に残す。呼び出し側 include_platform_cookbook と platform-purity は現状保たれている。既存 lint/reachability と container guard は削除せず前置き検証に利用する。setup 失敗の終了コードも契約へ揃える。

## 前提の反証で見つかった事実誤認

- ADR 0011:34〜37・:63 の不整合検出保証は、複数 target・引用 job 名・DNS 宛先・抽出されない FLEET 行を含まない（F1/F2/F4）。現在の設定が OK という実行結果から網羅性は導けない。
- ADR 0011:42 の理由必須・stale 検出は key 存在検査に留まる。job 名の別名という記述も実装の host label 変換と異なる（F3）。
- ADR 0012:35・README:23 の「必須 gate」と sentinel は同義ではない。sentinel は全 tool_missing の集約であり、必須性の情報を持たない（G2）。
- ADR 0012:43〜44 の doctor による auth_unavailable の代替判定は成立しない。STS の認証失敗は FAIL、SSM 権限不足は WARN で、必要な操作の成功とは一致しない（G1/G2）。
- bootstrap の間接 auth gate 実行経路は存在しない。ただし host 設定なしという記述は directory/profile とパッケージ移行の実体に反する（G6）。
- SSH_CONNECTION が sentinel 経路を切り替える事実はない。標準設定の sentinel は host-profile:33 と gate-report:80 により HOME/.setup_shin1ohno 配下で、wrapper:41〜42 と一致する。SSH 時の runner パス override 制限は別の機構である（G5）。

## 実行結果（./bin/check-host-configs | tail -1）

worktree ルートで `set -o pipefail` を有効にして指定コマンドを実行し、終了 0 を確認した。

```text
OK: hosts.json, prometheus.yml node-* jobs and host-profile FLEET agree (modulo config/host-policy.json).
```

Prometheus 差分は `git diff origin/main -- cookbooks/lxc-monitoring/files/prometheus.yml` で確認した。bin/converge、bin/setup、実機適用は実行していない。上記 OK は現在の入力に対する結果であり、本レビューの反例が検出されることを意味しない。
