# TODO — Cowork 移行 borderline 検証

仕分けマトリクス（`01-classification-matrix.md`）で「Code-only」判定したが、Cowork サンドボックスでの実証次第で「Skill 化可能」に変わる可能性がある 3 件を記録。実使用の中で必要性が見えた時点で実証 → 必要なら SKILL.md 化。

---

## 1. `verify` skill の Cowork 適合性

**現判定**: Code-only（Cookbook）
**疑義**: Cowork サンドボックスは Linux 環境で `npm test` / `cargo test` / `pytest` など標準テストランナーを実行できる。workspace folder 内の repo を対象にすれば部分的に動作するはず。
**未検証点**:

- Cargo / Rust の場合、target ディレクトリが mount に書けるか（zip 生成と同じ permission 問題が出るかも）
- Node ランタイム（npm install のキャッシュ）が permanent か session 限定か
- `code-reviewer` agent が Cowork で sub-agent として呼べるか
**実証手順**:
1. Cowork session で workspace folder に小規模 Rust crate を含むプロジェクトを置く
2. `cargo test` 相当の発話を試す（「テストを実行」）
3. 成否・所要時間・出力品質を記録
**Concrete first prompt to resume**: 「workspace の `<repo>` で test を走らせてください」

## 2. `ingest-batch` の縮小版

**現判定**: Code-only（local Cognee Docker 前提）
**疑義**: Cognee MCP 単体でも、複数ファイルを 1 ファイル 1 sub-agent で並列 cognify できる。Docker 直接アクセスが要らないシンプル版なら Cowork で動く。
**未検証点**:

- Cowork の Agent ツールから並列 sub-agent を起動した時、各 agent が独立した Cognee MCP セッションを持てるか（衝突が起きないか）
- `cognify` の async 完了を agent が待てるか（タイムアウト挙動）
**実証手順**:
1. PDF を 3-5 ファイル workspace に置く
2. `ingest-to-cognee` skill を順次呼ぶ vs 並列で呼ぶ — 所要時間と成功率を比較
3. 並列で問題ないなら `ingest-batch-mcp` を新スキルとして起こす
**Concrete first prompt to resume**: 「`<dir>` の全 PDF を Cognee に並列で取り込んでください」

## 3. `verify-data-integrity` の MCP-only 版

**現判定**: Code-only（docker exec / psql 直接前提）
**疑義**: Cognee MCP の `list_data` + `search` だけで「空 dataset 検出」「test data 汚染検出」「データ件数異常」の一部はカバーできる。SQL 直接アクセスを必要とする整合性チェック（Check B / C / E）だけ落とせば Cowork でも動く。
**未検証点**:

- `list_data` が dataset 名・data 件数を返してくれるか（空 dataset を識別可能か）
- `search` で test pattern（`'test ingest'` 等）を検索した時のヒット率
**実証手順**:
1. Cognee MCP `list_data` を呼んで返り値の構造を確認
2. test pattern search を 3-5 種類試す
3. カバー率が 50% 以上なら `verify-data-integrity-mcp` を新スキルとして起こす（残りは「local Cognee SQL 直接アクセスが必要」と明記）
**Concrete first prompt to resume**: 「Cognee の dataset 一覧と整合性をチェックして」

---

## 完了基準

3 件それぞれに対し:

- [ ] 実証したら、結果（成功 / 部分成功 / 失敗 + 理由）を Cognee に `cognify` で保存
- [ ] 「成功」「部分成功」だった項目は、対応する SKILL.md を `cowork-migration/03-skills/` に追加
- [ ] このファイルから当該項目を削除（commit と同時）
