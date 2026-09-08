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

## Review（adversarial, codex — `docs/adr/0011-0012-review-design.md`）

| # | 所見 | 採否 | 反映 |
|---|---|---|---|
| G1 | `bin/doctor` が固定 profile で STS するため、ssh-keys の TTY 自動選択（別名の有効 profile）を持つホストが正常な初回認証に到達できず entry を止める。加えて `awscli` インストール後の PATH 反映は子プロセス内だけで、親 shell には伝わらない | 採用（次段） | wrapper 側で必要な PATH を明示し、doctor の必須条件を entry と同じ認証契約（TTY 自動選択）に合わせる再設計が必要。fleet の限定 profile はそのまま固定し、Mac への admin 資格情報配布はしない。`TODO.md` に記録 |
| G2 | `record_gate_event` は tool/reason だけを記録し必須/任意を持たない。SSM 権限不足は WARN、gh 未認証も WARN、非 TTY の `auth_unavailable` は sentinel を残さず成功終了できる。ADR の「必須 gate 未充足を FAIL」は sentinel だけでは判定できない | 採用（次段） | gate に安定 ID と required/optional を持たせ、機械可読な結果で tool_missing / auth_unavailable / user_skip を区別して exit 3 にする再実装が必要。`TODO.md` に記録 |
| G3 | `bin/converge` の `rm -f`（前回 sentinel 削除）は `--dry-run` でも実行され、gate-report の書き込みは execute resource なので dry-run では走らない。`--dry-run --skip-doctor` で mitamae が 0 を返すと、前回の成功証跡を消したまま converged と報告する | 採用（次段） | dry-run では sentinel の削除・完了判定を行わないよう分岐し、表示を「計画の検査完了」に分ける再実装が必要。`TODO.md` に記録 |
| G4 | `require_external_auth` の対話ループ（functions:258〜259）に試行上限が無く、EOF は空文字に変換されて再チェックされる。自動化された無限再適用は無い（wrapper は bootstrap/entry を各 1 回しか呼ばない）という主張自体は正しい | 部分採用 | 「無限再実行はしない」を wrapper の呼出回数の説明に限定する訂正は本 PR の範囲。EOF 明示中断・試行上限の追加は G1/G2 の再実装と合わせて次段。全 gate の `only_if` 化は不採用（gate-report の集計設計と衝突） |
| G5 | `bin/bootstrap-lxc-creds` は資格情報ファイルを置くだけで awscli を導入しない。runner は entry 呼び出しの終了 0 だけで success/verified SHA を記録し、fleet は wrapper の完了契約（sentinel・doctor）に参加していない | 採用（次段） | fleet 向けの独立した移行条件（新規 LXC の初回 bootstrap 検証、未完了時の verified SHA 非更新）を別途定義する。runner の flock・SHA/role 検証・forced-command 制約は変更しない。`TODO.md` に記録 |
| G6 | bootstrap は host 設定を "持たない" と書いたが、実際は `functions:549`（host-profile 経由のディレクトリ作成）と `awscli/darwin.rb`（既存 Homebrew awscli 削除・profile ファイル登録）を経由し、entry のホスト種別検証（bare-metal 拒否等）より先に走る | 採用（文書 + 次段） | ADR の「host 設定なし」記述を実際の変更範囲に合わせて訂正（本節）。entry のホスト種別検証を bootstrap より前に置く再配置は次段。`TODO.md` に記録 |

**訂正**: 「bootstrap は host 設定を持たない」（Decision 2 の記述）は誤り。`bootstrap.rb` → `functions` → `host-profile` の include 経路で `~/.setup_shin1ohno` 等のディレクトリが作られ、`include_platform_cookbook "awscli"` の darwin 側は既存 Homebrew awscli の削除と profile ファイル登録を行う。「認証 gate を呼ばない」は正しい（該当する `require_external_auth` 呼び出し元はいずれも bootstrap の include グラフに無い）。

**次の段への追加**（G1/G2/G3/G5/G6、上表参照）: `bin/converge` の doctor 前置き・sentinel 判定・dry-run 分岐・fleet 移行条件は、本 PR の「唯一の入口」実装のまま次段の再実装対象として `TODO.md` に記録した。呼び出し側 OS 選択・platform-purity・既存 lint/reachability・fleet の runner 機構（flock・SHA/role 検証・forced-command 制約）は変更しない。
