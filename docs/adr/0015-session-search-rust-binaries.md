# ADR 0015: ccs の Rust 成果物を SHA と sha256 で固定して配る

**Status**: Accepted（2026-11-09、所有者の Rust 移行計画承認。S1 は基盤のみ）

## Context

ADR 0014 の commit pin と main 祖先検査を維持し、Rust の成果物を各ホストで
ビルドせず GitHub Releases から取得する。配布を決めるのは setup の commit
である。S1 の `session-search.rust` に host はなく、全ホストで Python を維持する。

## Decision

- `session-search.pin` と `session-search.rust` を 1 commit で更新する。
  後者は `pin`、`host`、3 ターゲットの `sha256` レコードを持つ。
  host が選ばれ、pin が一致し、対象 hash があるときだけ engine を Rust にする。
  不一致は WARN と Python へのフォールバック（`common.rb` の engine 判定）。
- 配置は `files/deploy-binary.sh` が対象ユーザーで行う。HTTPS 取得後に sha256 を
  確認し、実行権限、`_buildinfo` の commit/target を検査して rename する。
  `DEPLOYED_BINARY` は最後に書く。check はネットワークを使わない。
  取得失敗は WARN/exit 0、整合性不一致は ERROR/exit 1 で現状を維持する。
- 最新と直前のバイナリを保持する。Python 配置が成功するまで binary 配置も
  gate し、launcher が参照する過去のバイナリを先に掃除しない。
- S5 まで Rust ホストにも Python を配る。engine off は同じ pin の Python へ
  ネットワークなしで戻る。Python の pin へ戻す場合は pin と host 選択を同時に
  revert する。取得失敗中は gate が launcher を維持する。
- `bin/lib/session-search-era.sh` が main の完全履歴で初めて
  `crates/ccs/Cargo.toml` を追加した commit を求める。host が空、かつ pin が
  その真の祖先（Rust commit がなければ全祖先）だけを Python 時代とする。
  main 外、削除で隠した Rust の子孫、Rust 境界と別系統の merge は免除しない。
- Python 時代は平坦で実行可能な Python tree と server/vendor 同一性を検査する。
  Rust 時代は 3 成果物の sha256 と GitHub attestation を検証する。
  repository、release workflow、source/signer commit、main ref を固定し、検証前に
  バイナリを実行しない（`bin/lib/session-search-artifact.sh`）。
- manifest 検査は `BASE` を正とし、corpus OID、source_blob、最低本数、Python
  適合、native artifact 適合、出力の交差検査、ruleset を確認する。
  `bin/lib/session-search-conformance.py` は session-search の
  `tools/check_conformance.py` と同じ S1 ポリシーを持つ。
- 契約の pass limit は 8。corpus の `pass-limit` family の検出結果だけは、
  同じベクタを参照実装に通した種類と件数に厳密一致させる。他のベクタは検出
  0 件を要求する。この所有者決定で契約との整合を保つ。family は corpus の ID
  から取り、期待値は実参照実装で計算する。ID の手書き許可リストは持たない。
- release は 3 native runner で build/test する。S1 は `_buildinfo` を検査し、
  `_conformance` の明示的な未実装拒否を記録する。公開は全ターゲットの実適合と
  交差検査を通した main push のみ。PR/manual の入力に公開バイパスはない。
  S1 は tag/Release を作らず、ホストが取得する成果物も作らない。

## Operations and rollback

`bin/bump-session-search <sha> [--hosts a,b]` は release の全 hash と provenance
を検証し、2 ファイルを 1 commit にする。`--engine-off <host>` は host を外す。
PR 本文に旧新 SHA の compare リンクを維持する。

merge 順は session-search の S1 → setup の S1。setup の現在の Python pin は
動かさないため、どちらの PR 単独でもホスト切替は起こらない。S4 以降の pin 更新
には、対応する session-search main commit と公開済み適合成果物が必要になる。

R1 は setup の S1 commit を先に revert し、続いて session-search の基盤を
revert する。R4/R5 は engine off、R6 は最後の Python を含む pin と配布コードを
戻してから engine off にする。S6 でも既存の Python 配置物は削除しない。

## Validation

`test/test-rollback.sh` は実 Python tree の archive と fake origin/release で
前進、engine off、旧 pin、X→Y→X、取得失敗、sha 不一致、pin 不一致、Python
欠落、N17 を検査し、各状態で実 manifest/pin checker と launcher を実行する。
Linux と macOS の CI が同じ入口を使う。`test-deploy-binary.sh` は受信側の marker、
mode、hash、組込み commit と拒否時の不変性を確認する。N9/N10 は corpus runner、
N11 は artifact checker を壊した入力で検証する。

公開時の署名と provenance の検証仕様は
[GitHub CLI の公式検証仕様](https://cli.github.com/manual/gh_attestation_verify) に従う。
