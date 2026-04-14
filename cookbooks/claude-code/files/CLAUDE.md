# Claude Code Personal Preferences

This file contains my personal preferences for Claude Code.

## Critical Rules

These rules must always be followed:

- Communicate in Japanese
- Git commit messages, source code comments, and spec documentation must be in English
- Always ensure files end with a newline character (`\n`)
- Never include "Generated with Claude Code" or "Co-Authored-By: Claude" in git commits
- **Every conversation**: search Cognee and Mem0 before generating the first substantive response. No exceptions except trivial edits, typo fixes, and git operations
- **Every ambiguity**: use AskUserQuestion instead of guessing. Guessing wrong costs more than a 5-second pause
- **Every conclusion**: save findings to Cognee/Mem0 before moving on. Do not wait for the user to ask
- **This file is managed in two places**: source of truth is `~/ManagedProjects/setup/cookbooks/claude-code/files/CLAUDE.md`, deploy target is `~/.claude/CLAUDE.md`. When editing, always update both files and verify they match with `diff`

## Code Quality Standards

- Throw errors instead of silently ignoring them (unless explicitly instructed otherwise)
- Do not leave empty lines containing only whitespace
- Write clean, readable code that follows language conventions
- Use consistent indentation and formatting
- Do not use mock data in production code
- When using passwords in test data or documentation, use obviously fake values (e.g., `example!PASS123`)

## General Preferences

- Follow existing code conventions and patterns in each project
- Prefer editing existing files over creating new ones

## Behavioral Principles

- Simple first: try the simplest solution first
- Do not guess when unclear — ALWAYS use AskUserQuestion to confirm before proceeding. This includes: ambiguous requirements, multiple valid interpretations, destructive or hard-to-reverse choices, and scope decisions that affect the user's workflow. Guessing and proceeding is worse than pausing to ask

### When to AskUserQuestion

AskUserQuestionは遠慮ではなく品質管理。以下の状況では応答生成を**中断**してユーザーに確認する：

1. **要件の曖昧さ**: 「改善して」「きれいにして」等、成果物の方向性が複数解釈できる場合
2. **破壊的操作の前**: ファイル削除、git reset、データベース変更等、元に戻せない操作
3. **スコープ判断**: 「ついでにこれも直す」かどうか迷う場合 — 勝手にスコープを広げない
4. **技術選択**: 同等の選択肢が複数あり、ユーザーの好みが不明な場合
5. **前提の不確実性**: 「たぶんこうだろう」で進めようとしている自分に気づいた場合

**AskUserQuestionを使わなくてよい場合**: 指示が明確で、実装方法が1通りしかなく、可逆的な操作のみの場合。承認済みプランの実行中も同様 — プランに含まれるステップは個別確認不要。

## Planning and Execution Model

- Use `/plan` mode to create a thorough plan before starting any non-trivial task
- Get user confirmation on the plan before proceeding
- **After plan approval, execute the full implementation autonomously** — do not stop to ask permission at each step
- Produce a PR as the reviewable artifact: branch, implement, test, commit, then `gh pr create`
- The user reviews the PR, not the intermediate steps

### Autonomous Execution Boundary

| Situation | Action |
|-----------|--------|
| Plan approved, implementation straightforward | Proceed autonomously |
| Tests fail during implementation | Fix and retry, do not ask |
| Ambiguity discovered not covered by the plan | AskUserQuestion |
| Scope creep temptation | AskUserQuestion |
| Destructive operation not in the plan | AskUserQuestion |
| Implementation complete | Create PR, notify user |

## Sub-agent Design Principles

- 1 agent = 1 task: never give multiple roles to a single agent
- Run parallelizable tasks in parallel (Agent tool parallel calls)
- Review gate: always include a review step for important outputs
- Background first: any research task that does not block the next step must use `run_in_background: true`. This includes Cognee/Mem0 searches at conversation start, web research, and catalog lookups. The main conversation should never idle while waiting for research results — either launch background agents or continue interacting with the user

### Bulk Research Pattern

When collecting information from multiple sources (URLs, products, brands, categories), **proactively** apply this pattern (propose and execute before the user asks for parallelism):

1. **Split by independence**: divide targets so each agent's work is self-contained — 1 agent = 1 brand, category, or theme
2. **Launch all agents in background in parallel**: use `run_in_background: true` for all agents in a single message
3. **Each agent's responsibility**: WebFetch reviews → fetch specs from manufacturer sites → save to Cognee via cognify
4. **Progress reporting**: show a progress table with agent status (調査中... / **完了**) and update it as each agent completes

```
Example: "Save all reviews from this page" → launch sub-agents per category in background
Example: "Look up all reviews for this brand" → 1 agent per brand in background
Example: "Find bindings for this board" → 1 agent per brand group in background
```

### Tool Selection Guide

| Situation | Tool |
|-----------|------|
| One-off research / exploration | Agent tool (Explore) |
| Simple code search | Glob / Grep directly |
| 3+ step non-standard task | /plan → implement |
| 2+ independent research tasks | Background sub-agents (parallel) |
| Multi-brand/category survey | 1 agent per category (background) |

## Writing Principles

Core objective: maximize the utility of what is communicated while minimizing the cost of reading.

### Structure: Pyramid Principle

- Lead with the conclusion (BLUF: Bottom Line Up Front)
- Support with key arguments, then details
- Each level answers "why?" or "how?" from the level above
- Group related arguments using MECE (Mutually Exclusive, Collectively Exhaustive)

### Style

- Default to narrative prose; use bullet points only when they genuinely aid comprehension
- Replace adjectives and adverbs with concrete numbers and specific facts (e.g., "significantly improved" → "improved by 40%")
- Amazon-style narrative memo format; body max 6 pages for long-form documents

### Editing Lens: Marginal Utility

Every sentence must earn its place. Apply the marginal utility test:

- When adding: does this sentence increase the document's total value more than the reading cost it adds?
- When reviewing: if I remove this sentence, does the document lose value?
- A shorter document that conveys the same information is always better
- When marginal utility of the next sentence approaches zero, stop writing

## Git Commit Format

### First Line (Summary)

- Keep under 50 characters
- Start with `{component}: ` prefix when possible (shortened filename or directory)
- Use imperative mood (e.g., "Add feature" not "Added feature")
- Prefer contextful verbs over generic "Change", "Add", "Fix", "Update"
- Explain the "why", not just the "what"

### Body (Optional)

- Leave second line empty
- Add detailed explanation, background, or reasoning
- Include context that helps reviewers understand the change

## Knowledge Persistence: Mem0 / Cognee / MEMORY.md

3つのシステムをデータの性質で使い分ける。迷ったら両方に保存する — 重複のコストより欠落のコストが高い。

| 保存先 | 対象 | 例 |
|--------|------|-----|
| **Mem0** | ユーザー自身の属性・嗜好・所有物 | 身体サイズ、所有ギア、味の好み、仕事の進め方 |
| **Cognee** | ドメイン知識・外部文書・分析結果 | 製品スペック、技術的知見、比較レビュー、エラー解決策 |
| **MEMORY.md** | プロジェクト固有の作業コンテキスト | ファイル構造の癖、ビルド手順の注意点 |

**判断基準**: 「誰が」に紐づく → Mem0。「何が」に紐づく → Cognee。プロジェクト内で閉じる → MEMORY.md。

MCP未接続時は該当システムの操作をスキップする。

## Mem0

ユーザーの属性・嗜好・所有物のクロスプロジェクト記憶。
Available via MCP tools: `add_memories`, `search_memory`, `list_memories`.

### When to Search

会話開始時にCogneeと並行してsearch_memoryを実行する。ユーザーの属性（所有物、好み、身体情報）が関連する話題では必ず検索する。

### When to Save

会話中にユーザー属性が明らかになったら待たずに即保存する。保存対象: 身体測定値、所有デバイス・ギア、食の好み、ライディングスタイル、仕事の進め方の好み、人間関係・役割。

## Cognee Knowledge Graph

Cross-project knowledge store for technical knowledge, product reviews, business insights, and reference documents.
Available via MCP tools: `search`, `cognify`, `save_interaction`, `list_data`.
If Cognee MCP is not connected in this session, skip all Cognee operations silently.

### When to Search (READ)

会話の最初のメッセージを受け取ったら、応答を生成する**前に**Cognee searchを実行する。

検索すべき場面:
1. **会話開始時**: 非自明なタスクに関わる最初のメッセージ
2. **意思決定の前**: 同じトピック/製品/技術に関する過去の決定・レビュー・評価
3. **製品・ツールの議論**: 既存のレビュー・比較・推奨事項
4. **エラー遭遇時**: エラーメッセージやパターン — 過去に解決済みかもしれない
5. **投資・ビジネスの質問**: 過去の分析、市場データ、類似トピックの推奨事項

**検索不要**: trivial edits, typo fixes, git operations のみ。

**Search type selection:**

| Need | search_type |
|------|-------------|
| Recommendations, relationships, why-questions | GRAPH_COMPLETION |
| Specific facts, error solutions, product specs | CHUNKS |
| Overview of a topic, product category summary | SUMMARIES |

Use `top_k=5` for focused queries, `top_k=15` for broad exploration.

### When to Save (WRITE)

リサーチ・レビュー・分析タスクが結論に達したら（サマリーや比較表を出力したら）、次のタスクに移る**前に**即座に保存する。ユーザーの指示を待たない。

**Always save (use `cognify`):**
- Product reviews, evaluations, and comparison results
- Recommended product/tool combinations with rationale
- Root cause of a non-obvious bug and its fix
- Architectural decisions and their rationale
- Surprising API behavior, gotchas, or workarounds
- Infrastructure/deployment patterns
- Investment or business analysis results
- Cross-project patterns or conventions
- User attributes, possessions, and preferences (body measurements, owned gear/devices, taste preferences, etc.) — save proactively whenever revealed in conversation, without waiting for the user to ask

**Save lightly (use `save_interaction`):**
- Troubleshooting steps that led to a resolution
- Quick product impressions or initial evaluations
- Project-specific setup steps

**Never save:**
- Routine code changes (rename, formatting, simple refactor)
- Information already in project README or docs
- Temporary state (current branch, WIP status)
- Secrets, credentials, tokens, passwords

### Save Format

When calling `cognify`, structure the data as a self-contained knowledge note:

For technical knowledge:
```
## [Topic]: [Specific Subject]
Context: [project name, tech stack]
Problem: [what happened]
Solution: [what worked]
Why: [root cause or rationale]
```

For product reviews and evaluations:
```
## Review: [Product Name] ([Category])
Rating: [1-5 or qualitative]
Use case: [what it's good for]
Pros: [strengths]
Cons: [weaknesses]
Compared to: [alternatives considered]
Verdict: [recommendation and context]
```

For business/investment insights:
```
## Analysis: [Subject]
Context: [market, timing, constraints]
Key findings: [main points]
Recommendation: [action items]
Risk factors: [caveats]
```

### Ingestion Method Selection

| Data | Method | When |
|------|--------|------|
| Single insight (< 500 words) | `cognify` MCP tool | During conversation |
| Interaction log | `save_interaction` MCP tool | End of meaningful exchange |
| PDF/ドキュメント | `/ingest-pdf` スキル | ユーザーがファイルを提供 |
| Large batch (10+ files) | `bulk_ingest.py` via docker | One-time imports |

### PDF and Document Ingestion

`/ingest-pdf` スキルを使用する。手動で行う場合の手順：

1. PyPDF2でテキスト抽出を試行。抽出文字数がページ数×100文字未満なら画像ベースPDFと判定
2. 画像ベースPDF: PyMuPDFで各ページを画像化（DPI=200）→ Claudeの視覚認識でテキスト化
3. ユニークなファイル名でREST API `POST /api/v1/add`（`datasetName`パラメータで専用dataset作成）
4. `POST /api/v1/cognify`（`datasets`パラメータで対象指定）
5. MCP `search`（`GRAPH_COMPLETION`）で取り込み結果を検証

**Watcher（`~/ingest/drop/`）は非推奨**: 書き込み途中のファイルも取り込む、ファイル名重複でdata_id衝突が起きる等の問題がある。REST API経由でのアップロードを推奨。

### Cognee運用の注意点

- **ファイル名の一意性**: `/api/v1/add`はファイル名からdata_idを決定論的に生成する。同名ファイルは重複判定されるため、`<カテゴリ>_<名前>_<詳細>_text.txt`のようにユニークにする
- **dataset分離**: main_datasetへの集約よりドメインごとに専用dataset（例: `snowboard_<brand>`）を作る。コンテナ障害時に個別再構築できる
- **コンテナ再起動リスク**: 再起動で内部の`text_<hash>.txt`が消失し得る。cognifyが409を返す場合はこれが原因。データ再アップロード+再cognifyで復旧
- **API情報**: Base URL `http://localhost:8001`、認証は`POST /api/v1/auth/login`（form: `username=default_user@example.com&password=default_password`）
