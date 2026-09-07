# ADR 0010: memory-v2（MCP server + keeper）の配布単位を一つの MANIFEST に定義し、CI は配布物そのものを検証する

**Status**: Proposed (2026-09-07)

## Context

`cookbooks/lxc-es-memory` は memory-v2 MCP server（`files/memory-mcp/`、5 モジュール）と
memory-keeper（`files/memory-keeper/`、6 モジュール + prompts 2 本）を、cookbook 内に **手書きした
モジュール名リスト**で LXC へ配布してきた。実装ファイル・依存（`requirements-v2.txt`）・配布リスト・
テスト対象（`test_*.py`、httpx / voyage / identity を stub してソースツリー上で走る）が別々に管理
されている。

- 2026-08 #895 が `merge_rules.py` を追加したとき配布リストに載らず、keeper は 8/26〜29 の全 tick で
  `ModuleNotFoundError` になった（#931 で配布リストに追加）。ソースツリー上のテストはファイルが
  隣にあるので通り、配布物の欠落を検出できない。
- 8/17 には修正したヘルパーだけをテストして revise 経路の欠陥が残った（#889 で経路統合）。

CI の手動実インストール用レシピ（workflow_dispatch の real-install level）にも、OS 分割後に存在しない
`default.rb` を指す `include_cookbook` が 13 箇所（git, fzf, neovim, terraform, python, golang,
build-essential）残っていた。通常 PR の dry-run はこの分岐を実行せず、`bin/audit-cookbook-reachability`
は entry root だけを見るので、1 か月検出されなかった。

## Decision

### 1. 配布単位は `files/<unit>/MANIFEST` の 1 ファイル（本 PR で実装）

`memory-mcp/MANIFEST`・`memory-keeper/MANIFEST` に runtime ファイルを 1 行 1 つで列挙する
（`test_*.py` は CI 専用なので含めない）。cookbook はこの MANIFEST を読んで `remote_file` を生成する
（手書きリストを廃止）。配布リストとソースの不一致は `bin/check-memory-v2-manifest` が両方向で検査する:
ディレクトリにあって MANIFEST に無い runtime ファイル（#895 のクラス）、MANIFEST にあって存在しない
ファイル。

### 2. CI は配布物を空の環境へ入れて検証する（本 PR で実装、範囲は import と keeper 単体テスト）

同スクリプトが MANIFEST のファイル **だけ** を空ディレクトリへコピーし、`python3 -I`（user site も
環境も無し、`sys.path` は配布先だけ）で全モジュールを import する。keeper は標準ライブラリのみ依存なので
system python で走り、`test_merge_rules.py` も配布コピーに対して実行する。memory-mcp は
`requirements-v2.txt` を入れた使い捨て venv（CI が作る）で 4 モジュールを import する。

`server.py` は import 時に `asyncio.run(be.ensure_indices())` で ES へ接続する（ES ブートストラップが
モジュール読込に結合している）ため、hermetic な import ができない。本 PR では `py_compile` に留める。

`syntax-check` job（通常 PR）に載せる。既存の stub ベース回帰スイート（tags / ids / tag-preservation）は
そのまま残す。

### 3. CI の手動実インストールレシピは本番 role と同じ include 形にし、参照検査を通常 CI に載せる（本 PR で実装）

13 箇所を `include_platform_cookbook "<name>"`（roles/core・foundation・extras・programming が使う形）に
置換する。`bin/audit-cookbook-reachability` に条件 5 を追加し、`.github/workflows/*.yml` の
`cat > *.rb << 'EOF'` heredoc 内の `include_cookbook` / `include_platform_cookbook` / `include_role` /
`include_recipe` を entry root と同じ規則で解決し、存在しない参照を FAIL にする（heredoc レシピは
reachability には寄与させない — CI レシピからしか届かない cookbook は本番では dead）。修正前の実行で
13 件 FAIL、修正後 0 件を確認。

### 次の段（本 PR の範囲外、順序付き）

1. `server.py` の ES ブートストラップを import から lifespan（FastMCP の startup）へ移す。これが
   公開 API 往復テストの前提。
2. その上で CI に「配布物を空 venv へ入れて uvicorn で起動 → remember → browse → revise → get →
   forget を HTTP で往復し、stub ES のドキュメント変化まで assert する」ジョブを追加する。
   8/17 の教訓どおり戻り値ではなくデータ変化を見る。
3. MANIFEST を `pyproject.toml`（`[tool.setuptools] py-modules` または unit ごとの package 化）へ
   昇格し、cookbook は wheel を venv に `pip install` する。flat import（`import es_backend`）を
   相対 import に書き換える範囲は 2 ディレクトリ約 4,000 行。1〜2 が無い状態で先に package 化しても
   #895 のクラスは MANIFEST で既に閉じているので、優先度は 1〜2 の後。

## Consequences

- 新しいモジュールを追加して MANIFEST を更新し忘れると CI が落ちる。配布リストの更新は cookbook では
  なく MANIFEST 1 か所。
- CI の syntax-check job に venv 作成 + `pip install -r requirements-v2.txt` が増える（数十秒、
  manylinux wheel のみ）。
- 検査は import と keeper 単体テストまで。起動・公開 API・データ変化は次の段。
- 手動実インストールレシピの参照は通常 PR で検査されるが、レシピを **実行** するのは引き続き
  workflow_dispatch のみ。

## Rejected alternatives

- **いきなり Python package 化**: import 書き換え約 4,000 行 + cookbook の venv 導線変更を伴い、
  #895 のクラスを閉じるだけなら MANIFEST で足りる。順序を後ろにする（次の段 3）。
- **CI レシピを `include_role` に置き換える**: role は多数の cookbook を含むので real-install の
  実行時間と失敗面が大きく変わる。include の **形** だけを role と揃える方が小さい。
- **`server.py` の import 時接続を CI で stub する**: 配布物と実 wheel で import できることの証明に
  ならない。結合自体を解く（次の段 1）。
