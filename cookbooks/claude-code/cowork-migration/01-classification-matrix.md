# Cowork 移行 — 仕分けマトリクス

棚卸し対象: `~/ManagedProjects/setup/cookbooks/claude-code/files/` 配下の全ファイル
判定軸: Anthropic Agent Skills best practices を起点に、Cowork desktop の機能差分（hooks 不可・Linux 前提なし・skill/preference は登録可）を踏まえる
凡例:

- **Skill** — Cowork に SKILL.md として登録。`outputs/03-skills/` にドラフトあり
- **Preference** — Cowork の User preferences に貼り付け。`outputs/02-user-preferences.md` に統合済み
- **Project memory** — プロジェクト固有のため、Cowork 上では関連プロジェクトの memory として個別に持ち込む
- **Code-only** — Claude Code 固有機能（hook / mitamae / Bash 前提）。Cowork に持ち込まない
- **Bundle** — 上位 Skill の参照ファイルとして同梱（progressive disclosure）

---

## A. CLAUDE.md と docs/

| ファイル | 判定 | 理由 | 移行先 |
|---|---|---|---|
| `files/CLAUDE.md` | **Preference**（部分的に Skill / Code-only） | 全体は preference 化するには長すぎる。AskUserQuestion 規律 / Behavioral principles / Planning model は preference 必須。Compaction / 「This file is managed in two places」など Code 固有箇所は除外 | `02-user-preferences.md` に再構成 |
| `files/docs/knowledge-persistence.md` | **Preference + Skill** | 「Cognee/Mem0 をいつ search/save するか」は preference。Cognee 操作の API ディテール（filename uniqueness, troubleshooting）は skill の reference として使える | preference 抜粋 + `03-skills/cognee-knowledge-ops/` に詳細を bundle |

## B. Skills（既存 SKILL.md）

| ファイル | 判定 | 理由 | 移行先 |
|---|---|---|---|
| `skills/writing/SKILL.md` | **Skill** ✅ | Cowork でも文書作成は中核ニーズ。Pyramid Principle + marginal utility は OS 非依存 | `03-skills/writing/SKILL.md` に description 強化 |
| `skills/writing/personas/document-writer.md` | **Bundle** | writing skill の reference | `03-skills/writing/personas/` に同梱 |
| `skills/writing/personas/marginal-utility-editor.md` | **Bundle** | writing skill の reference | `03-skills/writing/personas/` に同梱 |
| `skills/writing/templates/dvq.md` | **Bundle** | writing skill の template | `03-skills/writing/templates/` に同梱 |
| `skills/writing/templates/rfc.md` | **Bundle** | writing skill の template | `03-skills/writing/templates/` に同梱 |
| `skills/interview/SKILL.md` | **Skill** ✅ | 要件定義インタビューは Cowork でも有効。AskUserQuestion を多用する設計が Cowork の対話モードと合致 | `03-skills/interview/SKILL.md` |
| `skills/research/SKILL.md` | **Skill** ✅ | Cognee MCP は Cowork でも利用可（deferred tools にあり）。Mem0 は接続次第。Cowork 用に Mem0 frontmatter を optional 化 | `03-skills/research/SKILL.md` |
| `skills/retro/SKILL.md` | **Skill** ✅（要改訂） | セッション振り返りは Cowork でも有用。ただし Claude Code の hook/CLAUDE.md/agents への落とし込みは preferences/Notion 等への提案へ書き換える | `03-skills/retro/SKILL.md` |
| `skills/research-domains/SKILL.md` | **Skill** ✅（簡略化） | 横断リサーチは価値あり。`domain-researcher` agent への依存を解き、本体に統合 | `03-skills/research-domains/SKILL.md` |
| `skills/feature-parity/SKILL.md` | **Skill** ✅ | コードベース比較は workspace folder 上の repo に対して有効 | `03-skills/feature-parity/SKILL.md` |
| `skills/security-review/SKILL.md` | **Skill** ✅ | git diff があれば動く。Cowork でも repo を扱える | `03-skills/security-review/SKILL.md` |
| `skills/verify-cognee/SKILL.md` | **Skill**（条件付き） | Cognee MCP 接続時のみ有効。description で Cognee 接続を明示 | `03-skills/verify-cognee/SKILL.md` |
| `skills/ingest-pdf.md` | **Skill**（条件付き、要書き換え） | Cowork は組み込み `pdf` skill を持つので PDF 抽出は不要。**Cognee への取り込み**部分のみ skill 化 | `03-skills/ingest-to-cognee/SKILL.md`（縮小版） |
| `skills/verify/SKILL.md` | **Code-only** | npm/cargo/bundle 等のローカルツール前提。Cowork で workspace 内 repo に対しては部分的に使えるが、Cowork は bash サンドボックス + 制限付き。code-reviewer 連携も Code 専用。スコープ外 | 持ち込まない |
| `skills/check-services/SKILL.md` | **Code-only** | systemd 前提（Linux サーバ運用）。Cowork は Linux サンドボックスを持つが systemd は無し | 持ち込まない |
| `skills/ingest-batch/SKILL.md` | **Code-only** | local Cognee Docker + MCP cognify 前提。Cognee MCP 単独では並列 ingest の制御不可 | 持ち込まない（必要なら simplified 版を後日） |
| `skills/load-test/SKILL.md` | **Code-only** | Docker サービス前提。Cowork のサンドボックスでは docker stats 不可 | 持ち込まない |
| `skills/setup-release-plz/SKILL.md` | **Code-only** | gh CLI + Rust toolchain + repo 編集前提 | 持ち込まない |
| `skills/verify-mise-backend/SKILL.md` | **Code-only** | mise CLI 前提 + cookbook 編集ワークフロー専用 | 持ち込まない |
| `skills/verify-data-integrity/SKILL.md` | **Code-only** | docker exec / psql 直接アクセス前提 | 持ち込まない |

## C. Rules

| ファイル | 判定 | 理由 | 移行先 |
|---|---|---|---|
| `rules/writing.md` | **Bundle**（writing skill 内へ） | writing skill と内容が重複。skill 側に集約 | writing skill の reference 節 |
| `rules/architecture.md` | **Preference** | OS 非依存の設計原則 | preferences に統合 |
| `rules/debugging.md` | **Preference** + **Skill** に分割 | Silent failure / Fix-loop escalation などコア原則は preference。"Read source before researching"・"Frame the failure class" 等の長文プロトコルは skill `debugging-protocol` 化を検討 | preference に圧縮抜粋 + 詳細は skill 候補（任意） |
| `rules/editing.md` | **Code-only** | Edit tool race condition / git mv の Read キャッシュ — Claude Code の Edit ツール固有 | 持ち込まない |
| `rules/git-commit.md` | **Code-only** | PR ワークフロー詳細・gh CLI 前提・branch hygiene。Cowork から git 操作は限定的 | 持ち込まない（Cowork で git する時は project memory に必要部分のみ） |
| `rules/sub-agents.md` | **Preference** + **Skill** | "1 agent = 1 task" / parallelize / background-first は preference。"Long-running task ownership" 等の詳細プロトコルは skill 候補 | preference に圧縮 + 必要なら skill |
| `rules/mcp-config.md` | **Code-only** | `.mcp.json` 設定 — Cowork は MCP を UI から接続 | 持ち込まない |
| `rules/claude-code-plugins.md` | **Code-only** | Claude Code plugin 連携ルール | 持ち込まない |
| `rules/data-collection.md` | **Preference** | Failure escalation ladder は OS 非依存 | preferences に統合 |
| `rules/frontend-dev.md` | **Project memory** | Next.js / Vite 前提のプロジェクトに固有 | 該当 repo の `CLAUDE.md` か Cowork project memory に |
| `rules/infrastructure.md` | **Project memory + Preference 部分** | 「Blast radius awareness」「Long-running operations」「Blocked command boundary」は preference 化候補。AWS cosmetic-drift 等は home-monitor 等の repo 専用 | 一部 preferences、残りは home-monitor の memory に |
| `rules/ios-build.md` | **Project memory** | weave-ios-core プロジェクト専用 | edge-agent / weave repo の memory に |
| `rules/mise-migration.md` | **Project memory**（setup repo） | setup cookbook 固有 | setup repo の memory に |
| `rules/release-plz.md` | **Project memory**（Rust repos） | Rust crates 用 | Rust repo（nuimo-rs / weave / edge-agent）の memory に |
| `rules/ruby.md` | **Project memory**（mitamae） | mitamae DSL 固有 | setup repo の memory に |
| `rules/rust.md` | **Project memory**（Rust） | cargo workflow 固有 | Rust repos の memory に |
| `rules/shell.md` | **Preference** 部分 + **Project memory** | "Locality check" 「Never chain two sudo」は preference 候補。残りは shell scripting に近い | preferences に圧縮抜粋 |
| `rules/remote-trigger.md` | **Code-only** | RemoteTrigger API 専用 | 持ち込まない |
| `rules/weave-protocol.md` | **Project memory** | weave-server / edge-agent 固有 | weave repo の memory に |

## D. Agents

| ファイル | 判定 | 理由 | 移行先 |
|---|---|---|---|
| `agents/researcher.md` | **Skill 内に統合**（任意） | Cowork は sub-agent 概念があり Agent ツール経由で呼べるが、agent 定義の登録 UI は限定的。research skill 内に inline で同様の指示を埋める | research skill にマージ |
| `agents/domain-researcher.md` | **Skill 内に統合** | research-domains skill にマージ | research-domains skill に統合 |
| `agents/session-retrospective.md` | **Skill 内に統合** | retro skill にマージ | retro skill に統合 |
| `agents/claude-docs-researcher.md` | **Code-only** | Claude Code docs 比較専用 | 持ち込まない |
| `agents/mitamae-validator.md` | **Code-only** | mitamae 専用 | 持ち込まない |
| `agents/service-health-monitor.md` | **Code-only** | systemd / `notify-send` 前提 | 持ち込まない |

## E. Hooks（settings.json）

すべて **Code-only**。Cowork は hook 概念が無い（最も近いのは「scheduled tasks」スキル）。

| ファイル | 判定 | 代替 |
|---|---|---|
| `hooks/pre-commit-test.rb` | Code-only | — |
| `hooks/block-co-authored-by.rb` | Code-only | preference に「Co-authored-by を絶対書かない」等の文言で代替可能 |
| `hooks/check-trailing-newline.rb` | Code-only | preference に「ファイル末尾に必ず改行」を追加 |
| `hooks/check-whitespace-lines.rb` | Code-only | preference に「行末の whitespace 除去」を追加 |
| `hooks/post-compact-remind.rb` | Code-only | Cowork は session compact が独立挙動。preference の Compaction 節と部分対応 |

## F. その他

| ファイル | 判定 | 理由 |
|---|---|---|
| `settings.json` | **Code-only** | Claude Code の permissions / hooks / plugins 設定 |
| `statusline-command.sh` | **Code-only** | Claude Code statusline |
| `default.rb` | **Code-only** | mitamae cookbook |

---

## サマリ

| カテゴリ | 件数 | 備考 |
|---|---:|---|
| Skill 化（要 description 強化） | 9 | writing / interview / research / retro / research-domains / feature-parity / security-review / verify-cognee / ingest-to-cognee |
| Bundle（上位 skill の参照） | 4 | writing 配下 personas + templates |
| User Preferences | 1 統合ファイル | `02-user-preferences.md` |
| Project memory（プロジェクト別） | 8 | frontend-dev / infrastructure 一部 / ios-build / mise-migration / release-plz / ruby / rust / weave-protocol |
| Code-only（持ち込まない） | 14+ | hooks / settings.json / mitamae 関連 / verify / load-test 等 |

検証: `files/` 配下の `*.md` `*.rb` `*.json` `*.sh` を `find` で列挙し、本表との突合は `06-verification-checklist.md` を参照。
