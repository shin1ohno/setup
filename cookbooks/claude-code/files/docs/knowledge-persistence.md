# Knowledge Persistence: Memory (v2)

Doctrine for when and how to search + save durable knowledge. `@`-imported by CLAUDE.md, so this file is always-loaded. The self-hosted Cognee stack (REST `localhost:8001`, ChromaDB, `docker compose cognee`, `bulk_ingest`, the `~/ingest/drop/` watcher) and its MCP tools (`cognify` / `save_interaction` / cognee `search`) were fully retired. The memory-v2 stack is now the single knowledge store — use its tools (`recall` / `remember` / `ingest`).

## Local write fallback (host-agnostic)

If a knowledge-WRITE tool (`remember`, `ingest`, `revise`, `forget`) is denied in this session, a local memory MCP may be registered on this host for writes — use the local equivalent instead (`mcp__memory-local__*`). READS (`recall`, `browse`) continue to use whichever connector is available (hosted or local). On hosts where the local server is not registered, the connector write tools are allowed and this note is a no-op.

## "local" is NOT air-gapped — verify egress before routing work-sensitive data

`memory-local` (127.0.0.1) names the **MCP server location**, not the LLM/embedding backend. Embedding may call **external vendor APIs** (Voyage, OpenAI, etc.) depending on container config, so "local" storage can still **egress content to a third party** on every write. Before routing any work-sensitive content (employer KPIs, product metrics, internal business data) through a local MCP:

1. Probe the actual egress:

   ```bash
   docker exec local-mcp-memory-1 env | grep -iE 'LLM_(PROVIDER|ENDPOINT|MODEL)|EMBEDDING_(PROVIDER|ENDPOINT)|VOYAGE|OPENAI|ANTHROPIC'
   ```

2. If any `*_ENDPOINT` points to a vendor API (`api.openai.com`, …), treat that MCP as equivalent to that vendor for data-sensitivity purposes — route work data through it only when the vendor is sanctioned for that data class, and **never** to a personal home-lab / personal Notion.
3. For structured data that only needs exact comparison (a KPI snapshot, a metrics diff), prefer a **local file (JSON)** — zero egress, exact diff, and the semantic graph adds nothing for fixed numbers.

The name `local` is not evidence of air-gap. Origin: 2026-06-19 kpi-delta-monitor loop — `docker exec env` showed `LLM_ENDPOINT=https://api.openai.com/v1`; routing Mercari KPI through it would have egressed to OpenAI. Snapshot moved to a local JSON file.

## Memory (unified v2 MCP)

Cross-project store for user attributes, preferences, possessions, durable facts, technical knowledge, product reviews, business insights, and reference documents. The claude.ai `memory` connector serves the unified v2 MCP (ElasticSearch + Voyage embeddings, hybrid BM25 + kNN recall). The old mem0 tool names (`add_memories` / `search_memory` / `list_memories`) are RETIRED — use:

- `recall(query, type?, top_k?, filters?)` — hybrid search over all memory (was `search_memory`). `type` optionally scopes to `fact` / `knowledge` / `episode`.
- `remember(content, type, tags?)` — persist a memory; `type` MUST be explicit: `fact` (atomic durable fact — the `add_memories` replacement), `knowledge` (a document/chunk — technical insight, product review, bug root-cause, architectural decision), or `episode` (session summary / light interaction).
- `browse(type?, filters?, sort?, limit?)` + `memory_stats()` — list + counts (was `list_memories`).
- `ingest(document, dataset, doc_key)` (upsert a whole document), `revise(id, content)`, `forget(id)`, `get(id)` — document/edit ops.

Async write model: a write is stored immediately as `raw`, then a keeper (on the es-memory host, `claude -p`) reconciles it (ADD/UPDATE/NOOP dedup) within a tick or two. Transparent to callers — keep saving; a just-written item becomes searchable in its reconciled form shortly after. There is no synchronous extraction step, so no timeout-and-retry dance (this replaces the retired cognify-timeout / `pending-cognify` fallback).

### When to Search (READ)

Run `recall` at conversation start, **before** generating a response to the first message. Also search before decisions on the same topic/product/tech, on errors (may be solved before), and for investment/business questions. Scope with `type` — `fact` for user attributes (possessions, preferences, body measurements), `knowledge` for technical/product insight, `episode` for prior sessions. Use `top_k=5` for focused queries, `top_k=15` for broad exploration.

**No search needed**: trivial edits, typo fixes, and git operations only.

### When to Save (WRITE)

Save immediately — do not wait to be asked:

- **User attributes** revealed during conversation (body measurements, owned devices/gear, food preferences, riding style, workflow preferences, relationships/roles) → `remember(type='fact')`.
- **Research / review / analysis conclusions** (a summary or comparison table produced) → `remember(type='knowledge')`, or `ingest` for a full document. Save before moving to the next task.
- **Debugging sessions**: the save trigger is **root-cause identification**, not task completion. When you identify the root cause of a non-obvious bug with confidence, save it (`type='knowledge'`) immediately — before implementing the fix. The root cause and the failed hypotheses both have future value.

**Never save**: secrets/credentials/tokens, routine refactors, info already in README, or temporary state (branch/WIP).

### Save Format

Structure each `knowledge` note as a self-contained block: Topic / Context (project, stack) / Problem / Solution / Why. (Adapt the labels for reviews — Rating/Pros/Cons/Verdict — or analyses — Findings/Recommendation/Risks.)

### Documents / PDFs

For a whole document (a report, a spec, a long reference), use `ingest(document, dataset, doc_key)` — it upserts by `(dataset, doc_key)`, so re-ingesting the same key supersedes the prior version. For a PDF, extract the text first (PyPDF2 for text PDFs; render pages and read them for image-based PDFs), then `ingest` the extracted text.
