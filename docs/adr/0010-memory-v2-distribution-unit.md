# ADR 0010: memory-v2（MCP server + keeper）の配布単位を一つの MANIFEST に定義し、CI は配布物そのものを検証する

**Status**: Proposed (2026-09-07、adversarial 設計レビュー反映済み — `0010-review-design.md`)

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

同スクリプトが MANIFEST のファイル **だけ** を空ディレクトリへコピーし、`python3 -I`（user site と
PYTHONPATH を無効化し、cwd を明示挿入）で全モジュールを import する。保証は「ソースツリーの隣接ファイルが
欠落を偶然補えない」ことであり、interpreter 自身の stdlib / site-packages と環境変数は残る（レビュー F5）。
import 時に必須の env（`VOYAGE_API_KEY` / `ES_URL` / `ES_PASSWORD`）は placeholder を渡す — これは
配布物の完全性の検査であり、env generator の正しさの検証ではない。keeper は標準ライブラリのみ依存なので
system python で走り、`test_merge_rules.py` も配布コピーに対して実行する。memory-mcp は
`requirements-v2.txt` を入れた使い捨て venv（CI が作る）で 4 モジュールを import する。

`server.py` は import 時に `asyncio.run(be.ensure_indices())` で ES へ接続する（ES ブートストラップが
モジュール読込に結合している）ため、hermetic な import ができない。本 PR では `py_compile` に加え、
`server.py` の third-party import 行（mcp / starlette / httpx / uvicorn）を実 wheel に対して実行する
（2026-08 の `mcp.server.fastmcp` 消失による crash-loop はこの経路で検出できる — レビュー F7）。

MANIFEST の許容形は直下 `*.py` と `prompts/*.md` に限定する（cookbook が作るディレクトリはユニット root と
`prompts/` だけ。任意の相対パスを受けると CI のコピーは通り本番の `remote_file` が親ディレクトリ不在で
失敗する — レビュー F2）。ディレクトリ内の **全ファイル**（test_*.py と MANIFEST 以外）が MANIFEST に
あることを要求する（レビュー F3）。更新配布（削除・改名した旧モジュールの残骸、owner/mode）は本 PR の
保証範囲外で、次の段に記す。

`syntax-check` job（通常 PR）に載せる。既存の stub ベース回帰スイート（tags / ids / tag-preservation）は
そのまま残す。

### 3. CI の手動実インストールレシピは本番 role と同じ include 形にし、参照検査を通常 CI に載せる（本 PR で実装）

13 箇所を `include_platform_cookbook "<name>"`（roles/core・foundation・extras・programming が使う形）に
置換する。`bin/audit-cookbook-reachability` に条件 5 を追加し、`.github/workflows/*.{yml,yaml}` の
`cat > <name>.rb << 'EOF'` heredoc 内の `include_cookbook` / `include_platform_cookbook` / `include_role` /
`include_recipe` を root 走査と同じ規則（`::` 分割、`.rb` 補完、両 OS recipe）で解決し、存在しない参照を
FAIL にする。走査器が解析できない heredoc 形（`cat <<'EOF' > x.rb`、`tee`、`"EOF"`）は黙って無視せず
FAIL にする（レビュー F6）。heredoc レシピは reachability には寄与させない（CI レシピからしか届かない
cookbook は本番では dead）。修正前の実行で 13 件 FAIL、修正後 0 件を確認。

### 次の段（本 PR の範囲外、順序付き）

1. `server.py` の ES ブートストラップを import から lifespan（FastMCP の startup）へ移す。これが
   公開 API 往復テストの前提。
2. その上で CI に「配布物を空 venv へ入れて uvicorn で起動 → remember → browse → revise → get →
   forget を HTTP で往復し、stub ES のドキュメント変化まで assert する」ジョブを追加する。
   8/17 の教訓どおり戻り値ではなくデータ変化を見る。
3. 更新配布の収束: MANIFEST から消えたモジュールの削除（専用管理領域に限定）または版別ディレクトリ切替、
   owner/mode の検証（レビュー F4）。
4. MANIFEST を `pyproject.toml` へ昇格し、cookbook は wheel を venv に `pip install` する。flat module の
   `py-modules` 配布なら `import es_backend` 形は維持でき、import 書き換えは不要（レビュー F8）。
   名前空間 package への再編は別の判断。1〜3 の後に独立に評価する。

## Consequences

- 新しいモジュールを追加して MANIFEST を更新し忘れると CI が落ちる。配布リストの更新は cookbook では
  なく MANIFEST 1 か所。
- CI の syntax-check job に venv 作成 + `pip install -r requirements-v2.txt` が増える（数十秒、
  manylinux wheel のみ）。
- 検査は import と keeper 単体テストまで。起動・公開 API・データ変化は次の段。
- 手動実インストールレシピの参照は通常 PR で検査されるが、レシピを **実行** するのは引き続き
  workflow_dispatch のみ。

## Rejected alternatives

- **いきなり Python package 化**: 配布先（`/opt/es-memory/app-v2` 直置き）と unit の起動方法
  （`python3 <module>.py`）を変える。#895 のクラス（直下モジュールのリスト漏れ）を閉じるだけなら
  MANIFEST の方が小さい。wheel 化は unit・env・残骸の検証を代替しないので、順序を後ろにする（次の段 4）。
- **CI レシピを `include_role` に置き換える**: role は多数の cookbook を含むので real-install の
  実行時間と失敗面が大きく変わる。include の **形** だけを role と揃える方が小さい。
- **`server.py` の import 時接続を CI で stub する**: 配布物と実 wheel で import できることの証明に
  ならない。結合自体を解く（次の段 1）。

## Review（adversarial, codex — `docs/adr/0010-review-design.md`）

| # | 所見 | 採否 | 反映 |
|---|---|---|---|
| F1 | `File.readlines` は mruby に無く mitamae v1.14.0 で compile が停止 | 採用 | `File.read(...).split("\n")` に置換。`bin/lint-cookbooks` の mruby 禁止 API に `readlines` を追加（positive control で FAIL を確認） |
| F2 | サブディレクトリのエントリは CI を通り本番の `remote_file` が失敗 | 採用 | MANIFEST 許容形を直下 `*.py` と `prompts/*.md` に限定し、他は FAIL |
| F3 | runtime 全体の完全性・全モジュール import は未検証 | 採用（範囲限定） | ディレクトリ内の全ファイル（test_*.py / MANIFEST 以外）を MANIFEST と照合。保証の記述を実装範囲に合わせて限定 |
| F4 | 空ディレクトリへのコピーは更新配布を再現しない | 採用（文書） | 初回配布の完全性と更新時の収束を分けて記述、削除・改名・属性は次の段 3 |
| F5 | env・unit・依存環境を配布契約から外している | 部分採用 | `-I` の保証範囲を訂正、placeholder は完全性検査の手段と明記。env generator ↔ `os.environ[...]` の静的照合、unit ExecStart ↔ MANIFEST 照合、Python 版の一致は次の段（本 PR の範囲外） |
| F6 | 条件 5 の抽出漏れと root 規則との差 | 採用 | `.rb` 補完・`::` 分割を root と揃え、`.yaml` も対象、解析不能な heredoc 形は FAIL |
| F7 | server 除外で FastMCP/Starlette import が未検証 | 採用 | `server.py` の third-party import 行を実 wheel で実行 |
| F8 | package 化の却下理由が変更量を過大に固定 | 採用（文書） | 却下理由を「配布先と起動方法を保つ小変更」に改め、flat `py-modules` なら import 書き換え不要と明記 |
