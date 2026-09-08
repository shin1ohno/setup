# ADR 0010 設計レビュー（adversarial, codex）

## 所見

対象は Proposed の ADR 0010 と最小実装（`42dd9d5`、`2597a30`）。判定は high 2 件、medium 5 件、low 1 件。現行 MANIFEST 読み込みは、リポジトリ指定の mitamae で compile に失敗する。

### F1. MANIFEST 読み込みが mitamae v1.14.0 で停止する

- 深刻度: high
- 根拠: 観点 1・2・4。`cookbooks/lxc-es-memory/default.rb:208` は `File.readlines` を呼ぶ。`bin/setup:4` の指定と同じ mitamae v1.14.0 を使い、実 MANIFEST を `File.readlines` で読むだけの recipe を `local --dry-run` で実行すると、`undefined method 'readlines' (NoMethodError)`、終了 1。resource の converge より前に停止する。対照の `File.read(...).split("\n")` は同じ binary で終了 0。`bin/lint-cookbooks:603` の mruby 非対応 API 一覧に readlines はなく、Python の配布チェッカーも Ruby の deploy 経路を実行しない。
- 提案: `File.read(...).split("\n")` に置換し、lint の mruby 禁止 API に `File.readlines` を追加する。MANIFEST 読み込みと resource 生成を実際の mitamae で検証する小さい CI recipe を追加する。ソース管理された MANIFEST は converge 前から存在するため、compile-time に読むこと自体は正しい。生成ファイルを先読みする既存の `File.exist?` 問題とは区別する。

### F2. 未作成のサブディレクトリへの配布は CI が成功しても本番で失敗する

- 深刻度: high
- 根拠: 観点 1・2。`bin/check-memory-v2-manifest:44` は全エントリに `mkdir -p` するが、cookbook は `default.rb:171`、`:389`、`:396` の app/keeper ルートと keeper の `prompts/` しか作らない。`:212`、`:408` はファイルの `remote_file` だけ。scratch コピーに `helpers/new.py` を追加して MANIFEST に載せてもチェッカーは終了 0。mitamae v1.14.0 の scratch 内 `remote_file` で親がない宛先を指定すると `cp: ... No such file or directory`、終了 2 を再現した。`prompts/sub/` にも同じ欠陥がある。したがって ADR:65 の「#895 のクラスは既に閉じている」は、将来追加されるモジュール一般への保証として成立しない。
- 提案: 最小構成を維持するなら MANIFEST の許容形を直下 `.py` と `prompts/` 直下 `.md` に限定し、それ以外を CI で拒否する。任意の相対パスを許すなら親 directory resource も MANIFEST から生成し、チェッカーと本番で同じディレクトリ構造を検証する。

### F3. runtime 全体の完全性と全モジュール import は検証していない

- 深刻度: medium
- 根拠: 観点 1・2。`bin/check-memory-v2-manifest:36` の `find` は通常ファイルの `.py` と `prompts/*.md` のみを拾い、全階層の `test_*.py` を除外する。JSON、SQL、テンプレート、symlink は対象外。scratch に未登録の `data/runtime.json` を置いた状態でも終了 0 を確認した。`:46` の import 名生成は直下 `.py` だけで、F2 の `helpers/new.py` は登録されても直接 import されない。ADR:29–31、:69 と MANIFEST 冒頭の「runtime ファイル」「non-test file」は実装より広い。
- 提案: 保証を現在のファイル種別・階層に限定して明記するか、runtime/test の明示的区分を定義して全ファイルとの集合比較にする。ネストを認めるなら import 対象とデータ読込検証も追加する。依存の遅延 import や実行時のファイル読込は import 成功だけでは検出しないと記す。

### F4. 空ディレクトリへのコピーは更新配布を再現しない

- 深刻度: medium
- 根拠: 観点 2。`default.rb:211` と `:407` は現行エントリの追加・更新だけで、MANIFEST から削除した旧モジュールの削除 resource を生成しない。名前変更後も旧 `.py` が残り、その旧名を遅延 import する経路は空ディレクトリと異なる動作をする。`:214–216`、`:410–412` は全ファイル root:root/0644 固定だが、チェッカー `:44` は `cp` だけで所有者・実効 mode を検証しない。現在の `.py` と prompt は unit の root 実行に整合するが、実行可能ヘルパーや別 user の導入まで保証する設計ではない。
- 提案: 初回配布の完全性と更新時の収束を別の保証として記述する。旧版→新版の配布確認を追加し、専用管理領域に限った旧管理ファイル削除、または版別ディレクトリ切替を定義する。固定 mode/owner を単位の制約として明文化し、任意ファイルを受け入れるなら属性も検証する。

### F5. env・unit・依存環境を配布契約から外している

- 深刻度: medium
- 根拠: 観点 1・2。チェッカー `:63–65` は不足した ES/Voyage env を自動補完する。例えば env generator から `VOYAGE_API_KEY` 行を削除しても、このチェックは変わらず成功する一方、`memory-mcp/voyage.py:27` は本番で `KeyError` になる。生成箇所は `files/generate_env_v2.sh:42`、読み込み先は `files/systemd/memory-mcp-v2.service:15`。unit の ExecStart（同 `:24`、`memory-keeper-reconcile.service:33`）も MANIFEST と照合しない。CI は `test-setup.yml:590–592` の新規 venv＋requirements-v2 だが、本番は `default.rb:162–165`、`:190` の既存共有 venv＋base/v2 依存。keeper の `python3` は PATH 解決で、本番は `/usr/bin/python3` 固定。実測した検査用 Python は pyenv 3.12.2 だった。`python3 -I` でも通常の env と標準・環境側 site-packages は残る。`ES_URL` が残ることと `sys.path` を実測済みで、ADR:35–36 の「環境も無し」「sys.path は配布先だけ」は誤り。反対に user site/PYTHONPATH に依存する構成は `-I` の検査だけ失敗する。
- 提案: 「ソースツリー混入を防いだ import 検査」と保証を限定する。unit の起動パス、env 必須キーと generator の出力、requirements の導入順を静的に照合する。Python のバージョンを本番と揃え、明示した env だけで起動する別チェックを設ける。placeholder を認証・設定の検証済み根拠にしない。稼働 LXC の Python と wheel の現状は未確認。

### F6. audit 条件 5 は抽出漏れと既存規則との差を持つ

- 深刻度: medium
- 根拠: 観点 1・2・4。`bin/audit-cookbook-reachability:233–238` は `.yml` の生行に特定の正規表現を当てるだけ。実際の regex で `cat > x.rb <<EOF`、`<<-EOF`、`<<'EOF'` は MATCH、`<<"EOF"`、`cat <<'EOF' > x.rb`、`tee x.rb <<'EOF'`、開始行末のコメント付きは MISS を確認した。`.yaml`、YAML の折り返しで分割した開始行も対象外。`run: >` で `cat > x.rb` と `<<'EOF'` を等しいインデントの別行に置き、本文だけ深くした例は、YAML 解釈後の `bash -n` が終了 0 だが生行抽出は false になった。さらに `:262–263` は `include_recipe "cookbooks/functions/default"` を拡張子補完せず不存在とするが、既存条件は `:190` で `.rb` を補う。`include_role "x::y"` も `:259` は分割せず、既存 `:153–156` と異なる。ADR:51 の「entry root と同じ規則」は事実と異なる。Ruby include の単引用符・括弧形式の未検出は既存条件にも共通する制限。
- 提案: include 解決を共通関数にして既存条件と条件 5 の意味を統一する。最小の代替は、CI recipe を追跡対象 `.rb` に外出しして既存走査器に検査専用 root として渡すこと。CI root の到達集合は本番 reachability と別に保つ。heredoc を維持するなら許容する生成形式を定義し、非対応形式を黙って無視せず検査失敗にする。

### F7. server 除外は ES に無関係な起動 import まで未検証にする

- 深刻度: medium
- 根拠: 観点 2・3。`bin/check-memory-v2-manifest:53`、`:71` は server を除外して byte-compile する。これでは `memory-mcp/server.py:22–24` の FastMCP/Starlette import と実 wheel の互換性を検査しない。構文が正しく import 先が存在しない変更は `py_compile` を通る。`requirements-v2.txt:8–19` にも FastMCP import 消失による過去の起動障害が記載されている。ES 接続を避ける理由は正しいが、外部 wheel を入れた検査から公開入口を除くことで重要な故障経路が残る。
- 提案: 最小追加として ES に触れない FastMCP/Starlette の import と使用 API を実 wheel で検証する。lifespan 分離を先に行う順序は副作用削減として妥当だが、HTTP 往復試験の必須前提ではない。先にローカル stub ES を起動して ES_URL を向ければ現在の import-time bootstrap を含めて試験できる。外部 ES に接続せず、実 wheel と配布物を使う保証は維持できる。

### F8. package 化の却下理由が変更量を過大に固定している

- 深刻度: low
- 根拠: 観点 3。ADR:62–65 は `[tool.setuptools] py-modules` と package 化を選択肢に挙げる一方、:79 は package 化に「import 書き換え約 4,000 行」が必要として却下している。flat な `py-modules` の配布では `import es_backend` 等を維持でき、全ソース行数は import 変更行数ではない。wheel 化自体も unit・env・残骸の検証を代替しない。
- 提案: flat module の wheel 化と名前空間 package への再編を分けて変更量を見積もる。現段階で MANIFEST を採る判断は維持できるが、その理由を「配布先と既存起動方法を保つ小変更」に改める。順序はまず F1/F2 の配布実行保証、次に入口 import／往復試験とし、wheel 化は独立に評価する。既存 lint の deploy-list drift 検査（`bin/lint-cookbooks:456`）を拡張するだけでも直下モジュールのリスト漏れは検出できるが、配布コピー import の保証は得られない。

観点 4: OS 選択・platform-purity、薄い LXC エントリ・role 所有、IAM 境界への抵触なし — 13 箇所は呼び出し側の `include_platform_cookbook` への置換で、`pve/lxc-es-memory.rb:14–19`、`cookbooks/lxc-es-memory/platform:1`、role include、`default.rb:28–29` の profile 選択と `:256–269` の SSM 境界は変更していない。静的ガードレールとの不足・規則不一致は F1/F6、既存検査を使う代替は F8 に記載した。

## 前提の反証で見つかった事実誤認

- ADR:35–36 の `-I` は通常の環境変数、標準ライブラリ、環境側 site-packages を消さない。配布先だけの `sys.path` にはならない（F5）。
- ADR:51 の条件 5 は既存 root と同じ include 解決規則ではない（F6）。
- ADR:29–31、:65、:69 の完全性と閉包の主張は、対象種別・階層・配布実行に対して過大。直下 `.py` のリスト漏れは検出するが、現行 deploy は compile で停止し、サブディレクトリと非対象 runtime 資産の穴も残る（F1–F3）。
- ADR:79 の約 4,000 行の import 書き換えは flat module を wheel 配布するための必須作業ではない（F8）。
- 反証対象のうち「server.py は import 時に ES へ接続する」は成立する。`server.py:51` → `es_backend.py:453–457` が条件なしでクライアントを作り PUT を送る。到達可能な実 ES によるネットワーク実測はしていない。
- 「heredoc が entry root でなく従来未検出」は成立する。`audit-cookbook-reachability:71` の roots と `:113–126` の走査に workflow YAML はない。ただし ADR:21 の「entry root だけを見る」は不正確で、実際は root から再帰的に recipe を追跡する。

## 実行結果

worktree 原本で両 pipeline の終了コード 0。`MEMORY_MCP_PYTHON` 未指定のため memory-mcp の import は SKIP、keeper import と配布コピー上のテストは PASS。以下の最終行は server 起動・実 deploy の成功を意味しない。

```text
$ ./bin/check-memory-v2-manifest | tail -1
OK: memory-v2 distribution units are complete and importable.
$ ./bin/audit-cookbook-reachability | tail -1
OK: every cookbook is reachable or allowlisted.
```

追加検証は worktree 内 scratch のコピーと最小 recipe で実施。mitamae v1.14.0 の `File.readlines` は終了 1、`File.read(...).split("\n")` は終了 0、親未作成の `remote_file` は終了 2。ネストした `.py` の登録と未登録 JSON を追加したチェッカーのコピーは終了 0。実装ファイルは変更していない。
