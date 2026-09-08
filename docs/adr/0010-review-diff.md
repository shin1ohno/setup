# ADR 0010 実装 diff レビュー（adversarial, codex）

対象は `origin/main..fix/ci-recipes-and-memory-v2-manifest`（`f0e319a`、`ec2a63a`）。以下の行番号は PR 先端 `ec2a63a` 基準。判定は high 1 件、medium 3 件、low 1 件。現行 MANIFEST の mruby 障害は解消したが、許容する変更に対する配布保証と走査器の完全性には反例がある。実装は変更していない。

## 所見

### D1. MCP に許容した prompts の配布先を cookbook が作らない

- 深刻度: high
- 根拠: 観点 1・2。`bin/check-memory-v2-manifest:49` は両ユニットに `prompts/*.md` を許容し、`:55` は親を無条件に作る。`cookbooks/lxc-es-memory/default.rb:171` が作るのは app-v2 ルートだけで、`:218` の `remote_file` に親作成はない。prompts directory resource は keeper 専用の `:402` だけ。MCP に `prompts/probe.md` を作って MANIFEST に追記するとチェッカーは終了 0。同じ親不在条件の scratch `remote_file` は mitamae v1.14.0 で `cp: No such file or directory`、終了 2。`ec2a63a` 本文と ADR `docs/adr/0010-memory-v2-distribution-unit.md:48` の「ユニット root と prompts/ を作る」という説明は MCP には成り立たず、F2 の CI 成功・本番配布失敗が残る。現行 MCP MANIFEST は `.py` のみなので、この失敗を起こすのは許容形の prompt を追加する変更である。
- 提案: 最小修正として `prompts/*.md` を `unit == memory-keeper` の場合だけ許容する。MCP にも prompt が必要になった時点で directory resource と許容形を同時に追加する。

### D2. 非対応 heredoc を拒否する条件が YAML の折り返しを見逃す

- 深刻度: medium
- 根拠: 観点 1・2・3・4。`bin/audit-cookbook-reachability:236` は YAML 解釈前の行を読む。`:238` の本判定も `:240` の拒否判定も `.rb` と `<<` が同一行に必要。次の `.yaml` は YAML 解釈後の `bash -n` が終了 0、不存在 include を持つのに audit は終了 0。同じ include を通常の一行開始 heredoc に入れる対照は終了 1。したがって ADR `:63` と採否表 `:109` の「解析不能な heredoc 形は FAIL」は成立しない。F6 に既出の折り返し反例が残った。

  ```yaml
  - run: >
      cat > x.rb
      <<'EOF'
        include_cookbook "does_not_exist"
      EOF
  ```

- 提案: CI recipe を追跡対象 `.rb` に外出しし、既存 include 解決器を検査専用 root にも使う。CI の到達集合を本番 reachability に加えない。heredoc を維持するなら YAML の `run` 値を復元してから検査する。条件 5 に既存 resolver の複製を増やす修正は避ける。

### D3. ファイル列挙は symlink 拒否にも全ファイルの集合検査にもなっていない

- 深刻度: medium
- 根拠: 観点 1・2。`bin/check-memory-v2-manifest:37` は symlink が FAIL と説明するが、`:42` は検出したリンクを通常ファイルと同じ処理に渡すだけ。`:48` の `-f` はリンク先を追い、`:55` の `cp` も内容をコピーする。MCP の `alias.py -> ../memory-keeper/merge_rules.py` を MANIFEST に登録すると終了 0。配布単位外の内容を依存として取り込める。さらに `find` の改行区切りを `read` と `grep -qxF` へ渡すため、未登録の単一ファイル名 `scoring.py\nidentity.py`（`\n` は実改行）も既存の二つの登録行として扱われ、終了 0。`grep -qxF` 自体は通常の部分一致を許さず、`other_scoring.py` に対する `scoring.py` の照合は終了 1。穴はパス名を行に分割する前処理である。
- 提案: `find -print0` と NUL 対応の読み取りで一つのパスを保ち、リンクを明示的に拒否する。許容するパス文法を実ファイル側にも適用してから MANIFEST と集合比較する。これで不正名・単位外参照を import 検査の偶然に依存せず拒否できる。

### D4. server の import 行抽出が Python 文を壊し、副作用まで実行する

- 深刻度: medium
- 根拠: 観点 1・2・3。`bin/check-memory-v2-manifest:85` の grep は Python 構文を扱わない。`from mcp.server.fastmcp import (` に続く複数行 import は元ソースが構文正常でも開始行だけ抽出され、`python3 -I -` に渡すコードは `SyntaxError` になる。一方、`import mcp; print("EXTRA_STATEMENT_EXECUTED")` は追加文も丸ごと抽出される。追加文にネットワーク呼び出しがあればそれも実行するため「import 時に接続しない」という `:75` の説明はこの方式では保証できない。`import os, mcp.nonexistent` は抽出されず、既存の三つの import 行が残る場合はその存在検査を通過する。これらは実際の正規表現による抽出結果と AST で確認した。`server.py:22`〜`:24` の現在の単行 import は対象であり、FastMCP の import 消失という元の具体例への対策は実装されている。
- 提案: `ast.parse` で module 直下の `Import` / `ImportFrom` を選び、対象パッケージの import ノードだけを実行する。これなら複数行表記と同一行の追加文を区別できる。直下以外の条件付き import は保証外と明記する。現在の障害だけを塞ぐ最小案は、固定した FastMCP/Starlette の smoke import を明示して保証をその API に限定する。

### D5. cookbook と checker の MANIFEST 文法が一致しない

- 深刻度: low
- 根拠: 観点 1・2・3。`cookbooks/lxc-es-memory/default.rb:215` は各行を `strip` するが、`bin/check-memory-v2-manifest:30` はコメント・空行を除くのみで、`:41` も未加工の MANIFEST と照合する。`scoring.py` の行を ` scoring.py ` にするだけで cookbook は同じファイルを指定し、checker は不存在と文法違反を報告して `cp` で終了 1。CRLF にも同じ差がある。「cookbook が配布するものを検査する」という契約に対する偽陽性である。
- 提案: MANIFEST の空白・改行規則を一つに定義し、checker で一度だけ正規化したリストを全段に渡す。正規形以外を禁止する設計なら cookbook 側にも同じ拒否規則を持たせる。

## 設計レビュー採用項目の実装確認

| 項目 | 確認 |
|---|---|
| F1 | 閉じている — `default.rb:213`〜`:216` の loader を mitamae v1.14.0 で実行して終了 0。`bin/lint-cookbooks:604` に `readlines` が追加され、scratch の cookbook に再導入した対照は終了 1。MANIFEST 不在時は同 loader が compile 中に `Errno::ENOENT`、終了 1 となり、配布の一部だけを黙って省略しない。実 LXC 全体の apply は実行していない。 |
| F2 | 閉じていない — ネストした `.py` は拒否するが、MCP の `prompts/*.md` は CI が許容し cookbook が親を作らない（D1）。 |
| F3 | 閉じていない — JSON など未登録の通常ファイルを拾う範囲は広がったが、登録済み symlink と改行入りファイル名が通る（D3）。遅延 import・実行時データ読込の成功はこの検査の保証外。 |
| F4 | 閉じている（文書採用の範囲）— ADR `:51` と `:74` が残骸削除・属性・更新収束を対象外として明記。削除 resource の実装を済んだとは扱わない。 |
| F5 | 閉じている（ADR の部分採用の範囲）— ADR `:35`〜`:41` は stdlib/site-packages・通常 env が残ることと placeholder の意味を訂正した。env/unit/Python 版の照合は未実装。なお checker `:80` の「no env」と workflow `:576` の「nothing else on sys.path」は訂正されておらず、そのコメントを保証の根拠には使えない。 |
| F6 | 閉じていない — `.yaml`、`include_role` の `::` 分割、`include_recipe` の `.rb` 補完は実装済み。一行の tee・逆順・二重引用 delimiter の拒否も追加済み。折り返しの検出漏れは D2。単引用符・括弧形式の Ruby include の未検出は既存 root 検査にも共通する制限。 |
| F7 | 閉じていない — 現在の FastMCP/Starlette の三行を実 wheel へ渡す経路は追加済みだが、import 表記変更への偽陰性・偽陽性と追加文実行が残る（D4）。使用 API・server 全体の起動は未検証。 |
| F8 | 閉じている（文書採用の範囲）— ADR `:76`〜`:78` と `:92`〜`:94` は flat py-modules なら import 改変不要と訂正し、既存配布先・起動方法を保つ小変更を選択理由にした。 |

## 維持事項と簡素化の確認

観点 4: platform-purity、薄い LXC エントリ、role 所有、IAM 境界への変更はない。workflow の 13 箇所は呼び出し側の `include_platform_cookbook` への置換で、`pve/lxc-es-memory.rb:14`〜`:19`、`cookbooks/lxc-es-memory/platform:1`、roles の所有分担、`default.rb:28`〜`:29` の AWS profile と既存 SSM gate は維持される。MCP/keeper の owner・group・mode と MCP の restart 通知も従来どおり。

既存ガードレールとの関係は、mruby 禁止 API への追加が既存 check の拡張であり妥当。`bin/lint-cookbooks:456` の既存 deploy-list drift 検査は claude-code 専用であり、配布コピー上の import は検査しない。この方式を memory に広げても import 成功を保証できないため、新チェッカーには独自の役割がある。一方、audit 条件 5 の include 解決の複製は D2 の検査専用 root 化で減らせる。MANIFEST の保証を保つ最小修正は D1 のユニット条件、D3 のパス単位での拒否、D5 の一回の正規化であり、package 全面再編は不要。

CI の venv/pip 失敗は握りつぶさない。PR の `.github/workflows/test-setup.yml:581`〜`:583` は Ubuntu job の通常 `run` step で、既定 bash の `-e` により venv 作成または pip が失敗した時点で step が失敗し、checker へ進まない。`MEMORY_MCP_PYTHON` は成功時だけ渡るので、通常 CI は未指定による SKIP を利用しない。

`compile_only` は checker `:66` で memory-mcp の server に固定され、`:79` の interpreter 有効分岐内でのみ byte-compile と抽出 import を行う。未指定時は構文検査も SKIP。keeper は全直下モジュール import と配布コピーのテストを行う。`-I -` の抽出 import は cwd を sys.path に追加せず、実 wheel 側を検査する。現在の処理を server 自体の起動確認として扱ってはいけない。

## 実行結果

`git archive fix/ci-recipes-and-memory-v2-manifest` を当ノードの scratch に展開し、変更前のコピーで 3 スクリプトを実行した。各終了コードは 0。以下は各スクリプトの最終行。

```text
./bin/check-memory-v2-manifest
OK: memory-v2 distribution units are complete and importable.
./bin/audit-cookbook-reachability
OK: every cookbook is reachable or allowlisted.
./bin/lint-cookbooks
OK: no violations.
```

ローカル Python は 3.12.2、`MEMORY_MCP_PYTHON` は未指定で、memory-mcp は `SKIP`。keeper の import と `test_merge_rules.py` は PASS。MCP の実 wheel 検査は実行しておらず、最終行の「importable」をその証拠には使わない。D1/D3 の終了 0 もこの実行条件で得たもので、server 起動の成功を意味しない。D4 は wheel 互換性の実測ではなく抽出器の構文検証である。

反例はすべて scratch コピーで実施。mitamae の正常 loader は終了 0、不在 MANIFEST は終了 1、親不在の remote_file は終了 2。通常 heredoc の不存在 include と `File.readlines` 再導入はそれぞれ終了 1。ノードの `scripts/test.sh` は no-op で終了 0、`scripts/lint.sh` も終了 0。
