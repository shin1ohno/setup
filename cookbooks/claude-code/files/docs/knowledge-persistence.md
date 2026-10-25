# Knowledge Persistence: Memory (v2)

When and how to search + save durable knowledge (`@`-imported by CLAUDE.md, so always loaded). The memory-v2 stack is the single knowledge store — use `recall` / `remember` / `ingest`; the Cognee stack and its tools are retired. Detail: see `~/.claude/docs/knowledge-persistence-detail.md#retired-cognee-stack`.

## ファイル記憶は自動で MCP ストアにミラーされる — 手で二重書きしない

ファイル記憶（`~/.claude/projects/<slug>/memory/*.md`）は `hooks/mirror-file-memory.rb` が MCP ストアへ自動ミラーする（PostToolUse + SessionStart `--sweep`）。**同じ内容を `remember` / `ingest` で手動でもう一度書かないこと**。**このセッションで保存した結論が反証されたら、同 turn でファイル記憶を Edit する**（mirror が doc_key で上書き）。`remember` で別 note を足す訂正は禁止で、複製を作ってしまった場合だけ `revise` で直します。ミラーは `tool-output` なのでユーザー属性・嗜好・決定は `remember(type='fact')`。ファイル側が正本（削除すると sweep が forget）。失敗は `~/.claude/memory-mirror.log`。Detail: see `~/.claude/docs/knowledge-persistence-detail.md#memory-mirror-mechanics`.

## Connector timeout ≠ service down — curl the endpoint before declaring an outage

When an MCP connector call (`recall` / `remember` / `browse`) hangs or times out, probe the endpoint first: `curl -si --max-time 8 <endpoint URL>`. Any HTTP response (401 / 406 / 200) = service alive, fault is connector-local — continue via a fallback path and retry the connector later. No response / connection refused = genuine outage. Detail: see `~/.claude/docs/knowledge-persistence-detail.md#connector-timeout-origin`.

## "local" is NOT air-gapped — verify egress before routing work-sensitive data

A store's name (`local`, `work`, a loopback port, a box you own) names the MCP server location, not its LLM/embedding backend. Before routing work-sensitive content (employer KPIs, product metrics, internal business data) through a store: (1) read the embedding/LLM config the server process actually runs with; (2) judge by where each `*_ENDPOINT` points — a vendor API makes the store equivalent to that vendor (route work data only if the vendor is sanctioned for that data class, **never** to a personal home-lab / personal Notion), while a company-sanctioned gateway with local storage is the *correct* sink for work knowledge (pushing it to a personal store instead is the violation); probe per deployment; (3) prefer a local JSON file for exact-comparison data (KPI snapshots, metric diffs). Detail: see `~/.claude/docs/knowledge-persistence-detail.md#egress-probe`.

## Memory (unified v2 MCP)

Cross-project store (user attributes, preferences, possessions, durable facts, technical knowledge, reviews, business insights, reference documents) behind the claude.ai `memory` connector. Tools: `recall`, `remember(content, type, tags?)` with `type` explicit (`fact` / `knowledge` / `episode`), `browse` + `memory_stats`, `ingest` / `revise` / `forget` / `get`. Old mem0 names are retired. Writes reconcile asynchronously — keep saving, no retry dance. Detail: see `~/.claude/docs/knowledge-persistence-detail.md#memory-v2-tools`.

### When to Search (READ)

Run `recall` at conversation start, **before** responding to the first message; also before decisions on the same topic/product/tech, on errors, and for investment/business questions. Scope with `type` (`fact` user attributes, `knowledge` technical/product insight, `episode` prior sessions); `top_k=5` focused, `top_k=15` broad.

**No search needed**: trivial edits, typo fixes, and git operations only.

### When to Save (WRITE)

Save immediately — do not wait to be asked:

- **User attributes** revealed in conversation (body measurements, owned gear, food preferences, riding style, workflow preferences, relationships/roles) → `remember(type='fact')`.
- **Research / review / analysis conclusions** → `remember(type='knowledge')`, or `ingest` a full document — before moving to the next task.
- **Debugging**: the trigger is **root-cause identification**, not task completion — save it (`type='knowledge'`) before implementing the fix, with the failed hypotheses.

**Never save**: secrets/credentials/tokens, routine refactors, info already in README, temporary state (branch/WIP).

**TODO-shaped content** (anything with a close condition) MUST carry `tags:["todo"]` + an explicit close condition. Routing and loops: `~/.claude/docs/todo-management.md`.

### Save Format

Each `knowledge` note is a self-contained block: Topic / Context / Problem / Solution / Why (reviews and analyses adapt the labels). **A work record carries the fact, the internal reading of it, and the agent's own checkable assessment of that reading.** Detail: see `~/.claude/docs/knowledge-persistence-detail.md#save-format-origin`.

### Documents / PDFs

Whole documents: `ingest(document, dataset, doc_key)` — upserts by `(dataset, doc_key)`, so re-ingesting supersedes. PDFs: extract text first (PyPDF2 for text PDFs; render and read pages for image PDFs), then `ingest`.
