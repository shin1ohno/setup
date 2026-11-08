# ADR 0014: ccs を独立リポ `shin1ohno/session-search` へ移し、setup は SHA pin で取得・配置・設定を持つ

**Status**: Accepted（2026-11-08、所有者の決定。Linear SH1-115）

## Context

`ccs`（セッション検索のクライアント）の Python パッケージとテストは `cookbooks/session-search/files/ccs/` にあり、setup の CI が毎回そのスイートを回していました。パッケージは stdlib だけで動き、setup の helper に依存しません。

ADR 0013 は ai-memory について、アプリを独立リポへ移し、setup が 40 桁の SHA を pin して各ホストが匿名 HTTPS で取得する形を決めています（Decision 8、S3）。ccs にも同じ形を使います。ccs の配布先は CT 119 ではなく開発機と Mac で、取得は対象ユーザーの権限で動きます。

ccs は server 側の `session_redact.py` と `session_codex.py` を同じパッケージに入れて配ります（`ingest.py` と `extract.py` がパッケージから import します）。この 2 本の正は server の木にあるので、リポが分かれても一致を保証する必要があります。

## Decision

| 項目 | 決定 |
|---|---|
| 置き場 | 新リポ `shin1ohno/session-search`（public） |
| 移す範囲 | パッケージ（`ccs/*.py`）とテストだけ。launcher、sweep の unit、session-ingest hook、session-search skill、Hydra 登録は setup に残す |
| 履歴 | 持ち込まない。初回 import は setup@e2d1e01 の写しで、差分は `tests/support.py` のパス 1 行だけ |
| 版 | `cookbooks/session-search/session-search.pin` に 40 桁の SHA を 1 行で持つ。tag は使わない |
| 取得 | 各ホストが匿名 HTTPS で取得する。GitHub の資格情報は置かない |
| pin の条件 | session-search の main の祖先に限る。配置時と setup の CI の両方で確かめる |
| 統制 | main は PR 必須、CI 必須、承認 0、force push と削除を禁止、bypass なし |

### 配置

`files/deploy-pinned.sh` を対象ユーザーが読める `~/.local/share/session-search/` に置き、対象ユーザーの権限で実行します。pro-dev の auto-mitamae は、対象ユーザーが読めない checkout から root で適用するためです。

スクリプトは git のユーザー設定とシステム設定を無視して fetch し、`git cat-file blob` で取り出した各ファイルの OID を `ls-tree` の OID と照合してから、staging をパッケージの位置へ差し替えます。最後に `DEPLOYED_MANIFEST` と `DEPLOYED_SHA` を書きます。`check` モードはネットワークを使わず、pin・OID・余分な `*.py`・mode を確かめます。cookbook はこれを `not_if` と後続の gate に使うので、手元のドリフトは次の apply で直ります。root の apply では gate も対象ユーザーへ権限を落として実行し、対象ユーザーが書けるスクリプトを root で動かしません。

fetch の失敗（offline、GitHub の障害）は WARN を出して exit 0 で、今の配置を変えません。配置が 1 度も無ければ何も入らず、依存するリソースは gate で止まります。祖先でない pin、OID の不一致、不正な pin は ERROR で非 0 にし、今の配置を変えません。

### vendor の写し

session-search は `vendor/memory-mcp/session_redact.py` と `session_codex.py` に写しを持ち、配置時にパッケージへ入れます。setup の `bin/check-memory-v2-manifest` が、pin の写しと `cookbooks/lxc-es-memory/files/memory-mcp/` の一致を両ファイルについて検査します。写しが無い場合と取得できない場合は FAIL です。

ADR 0013 の W7 で server の木が setup から消えると、一致検査の相手は ai-memory の pin の `memory-mcp/` になります。検査は `BASE` 引数でその checkout を受け取れるので、`bin/check-ai-memory-pin` からの実行がそのまま残ります。

### pin の上げ方

40 桁の SHA を変える PR を setup に出し、本文に `https://github.com/shin1ohno/session-search/compare/<old>...<new>` を載せます。差分が SHA だけなので、コードの変更はこのリンクでレビューします。

server の redactor か codex adapter を変えるときは、先に session-search の写しを更新して merge します。次に setup の 1 つの PR で server のファイルと session-search の pin を一緒に変えます。片方だけでは一致検査が落ちます。setup の server の木が ai-memory の写しである間は、`ai-memory.pin` も同じ PR で動かします。

## Consequences

- 統制が軽くても、session-search への merge は pin が動くまでどのホストにも何も配りません。ホストへ届く起点は setup の commit のままで、main の祖先検査が未 merge の commit を退けます。このため ADR 0013 S4 の承認 1 は要りません。
- ccs の変更は、session-search の PR と setup の pin の PR の 2 本になります。
- ccs のスイートは setup の CI から消え、session-search の CI（runner の python3 と Python 3.9）で走ります。setup の CI には pin の形式と祖先の検査、一致検査、`deploy-pinned.sh` の密閉テストを置きます。
- 各ホストは次の apply で `~/.local/share/session-search/src` に git リポジトリを持ちます。
- ADR 0002・0003 は変更しません。session-search は IAM・KMS・SSM 書き込みの定義も AWS の principal も持たないアプリだけのリポで、ai-memory と同じく対象外です（ADR 0013「ADR 0002・0003 との関係」）。Status 行に本 ADR への参照を足しました。

## Rejected alternatives

- **ai-memory に ccs を入れる**: サーバの統制（承認 1）がクライアントの変更にも掛かり、配布先も違います。
- **浮動 ref（main）を converge ごとに取得**: session-search への push が setup の commit も canary も経ずにホストへ載ります（ADR 0013 S2 と同じ）。
- **tag pin・release tarball・wheel**: tag は動かせる者に経路を開き、tarball と wheel は release の仕組みを先に要します（ADR 0013 S3 (i)、決定事項 2）。
- **vendor の写しを持たず、配置時に server の木から取る**: `session_redact.py` が setup から消える W7 で取得元がなくなり、session-search 単体でテストもできなくなります。
- **履歴を持ち込む**: ADR 0013 の決定事項 5 と同じ理由で持ち込みません。
