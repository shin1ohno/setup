# ADR 0012: 初期構築と通常適用を分ける — `bin/converge` の一入口と incomplete 判定

**Status**: Proposed (2026-09-07)

## Context

README は「新規マシンでは同じ entry recipe を **二度** apply する」と説明していた。原因は構造的で、
`require_external_auth`（`cookbooks/functions/default.rb`）が `aws` の存在を **compile 時** に確認する一方、
`aws` を導入する resource（`cookbooks/awscli`）は converge 時に動く。新規マシンの初回 apply では全 SSM
gate が `tool_missing` で skip され、2 回目で初めて設定される。8 月に gate-report（`.gate-rerun-required`
sentinel + RE-RUN REQUIRED banner）と `bin/doctor` の警告が加わり **見える** ようにはなったが、二度適用
という依存構造そのものは残っていた。

`bin/doctor` は読み取り専用の事前診断（FAIL = converge できない、WARN = 縮退）、`gate-report` は
apply 末尾で gate の結果（`ok` / `satisfied` / `tool_missing` / `auth_unavailable` / `user_skip`）を
集計する。両者を活用し、新しい仕組みは増やさない。

## Decision

### 1. `bin/converge <entry.rb>` を唯一の入口にする（本 PR で実装）

順序は固定: `bin/setup`（mitamae バイナリ）→ `mitamae local bootstrap.rb`（前提ツール）→ `bin/doctor`
（外部前提の検証、読み取り専用）→ `mitamae local <entry>.rb`（**新しいプロセスで再コンパイル**。gate は
導入済みのツールを見る）→ 判定。sudo で包まない（cookbook が resource 単位で昇格する既存方針）。

### 2. `bootstrap.rb` は「gate が存在を確認するツール」だけを入れる（本 PR で実装）

`include_recipe functions` + `include_platform_cookbook "awscli"` のみ。認証 gate も host 設定も持たない。
追加は「どこかの `require_external_auth` が `tool_binary` にその binary を指定している」ことを条件にする
（現状 `aws` の 1 件）。呼び出し側 OS 選択（`include_platform_cookbook`）と platform-purity は維持。

### 3. incomplete と任意省略を区別する（本 PR で実装）

`bin/converge` の終了コード: `0` = converged、`3` = **INCOMPLETE**（doctor FAIL / bootstrap 失敗 / mitamae
非 0 / apply 後に `.gate-rerun-required` が残る = 必須 gate が tool_missing で skip された）、`2` = 引数
エラー。operator がプロンプトで省いた任意機能（gate reason `user_skip`）は gate-report に skipped として
並ぶだけで incomplete にしない。無限再実行はしない（再実行は operator が原因を直してから）。

CI は `bootstrap.rb` を darwin / linux 両 job で dry-run する。

### 次の段（本 PR の範囲外）

1. `auth_unavailable` を exit 3 に含めるかの線引き: 今は doctor の FAIL がその役を担う（doctor が
   profile 不在・鍵不在を FAIL にする）。gate-report の `auth_unavailable` 集計を `bin/converge` が
   直接読む形（metric ではなく機械可読な出力ファイル）に寄せる。
2. fleet（`pve/lxc-*.rb`）は auto-mitamae の runner が入口で、bootstrap は `bin/bootstrap-lxc-creds` が
   担う。runner 側で `bootstrap.rb` を先に流す価値は、gate の `tool_missing` が fleet で観測されたときに
   判断する（現状 fleet は awscli を role 経由で導入済み）。
3. README の「初回は TTY が必要」は残る（sudo / AWS 認証のプロンプト）。

## Consequences

- 新規マシンの手順は 1 コマンド。二度適用の知識は不要になる。
- 既存マシンの通常再適用も `bin/converge` で統一できる（bootstrap は no-op、doctor は数秒）。
- `--skip-doctor` は CI 用の逃げ道。人が使うときは doctor の FAIL を読む。

## Rejected alternatives

- **gate を converge 時評価に変える**（`only_if` 化）: gate は cookbook の compile 可否を決めており、
  skip した cookbook の resource 群を登録しない設計。converge 時評価に変えると SSM 依存の resource が
  条件付きで大量に登録され、dry-run の可読性と gate-report の集計が崩れる。
- **entry recipe の先頭で awscli を include して同一プロセスで解決**: compile と converge の順序は
  mitamae の評価モデル（`~/ManagedProjects/setup/.claude/rules/ruby.md`）で固定。同一プロセスでは解けない。
- **`bin/mitamae` ラッパーで自動的に 2 回目を回す**: 「未充足を success として隠す」形になる。
  incomplete を明示して止める方を採る。
