# 外部ツール参照の規律

外部 CLI / npm パッケージ / GitHub リポジトリを参照する際の必須手順。本セッションでの `ncli` 名 4 往復ループの再発防止。

## Probe-before-assert（強制）

外部ツールの正体・インストール元・コマンド名・能力を文書に書く前に必ず一次情報で確認する。training-data からの記憶や類推で書かない。

### 確認すべき項目と手段

| 主張 | 確認コマンド |
|---|---|
| 「コマンド `X` が存在する」 | `which X` |
| 「パッケージ `Y` の実体は `Z`」 | `npm view Y name version repository.url` |
| 「GitHub リポジトリ `<org>/<repo>` に skill / README がある」 | `gh api repos/<org>/<repo>/contents/<path>` |
| 「最新リリースは `vX.Y.Z`」 | `gh api repos/<org>/<repo>/releases/latest --jq .tag_name` |
| 「`npx <pkg>` で実行可能」 | `npx <pkg> --version`（or `--help`） |
| 「インストール手順は X」 | リポジトリの README を `gh api repos/.../readme` で取得して確認 |

### 違反パターンの例

- 「`ncli` はメルカリ社内 CLI」と書く（`which ncli` で `@sakasegawa/ncli` の絶対パスが出る、社内製ではない）
- 「`kouzoh/notion-cli` からインストールすると `ncli` が入る」と書く（実際は `notion-cli` コマンド、リポジトリも別）
- skill の `allowed-tools: Bash(npx <pkg> *)` 行を本家 README 未確認で書く

## 同名パッケージ・複数候補の扱い

ローカルに `which X` を実行した結果と、ユーザーが指している X が一致しない可能性がある場合:

1. 候補を probe で列挙（`which -a X`、`npm ls -g`、ユーザー履歴の Slack/Notion 検索）
2. 列挙結果が複数なら AskUserQuestion で「どちらの X か」を確認
3. ユーザー言及の X が「メルカリ社内」「公式」等の修飾語を伴う場合、その属性に matching する候補のみ提示

## 公式プラグイン優先

参照対象のツールが Claude Code 用の skill / plugin を公式に提供している場合、自作の skill より公式版を採用する。

確認手順:
- `kouzoh/coding-agent-plugins` 配下の `plugins/<tool-name>/` を `gh api` で確認
- `anthropic-agent-skills` 等のマーケットプレイス確認
- 公式 skill が見つかったらリポジトリへ vendoring（コピー）する。改変は最小限

## 適用範囲

- skill / agent の作成・更新
- CLAUDE.md / README.md / rules への外部ツール言及
- インストール手順の記述
- 「このツールでできる/できない」の能力主張
