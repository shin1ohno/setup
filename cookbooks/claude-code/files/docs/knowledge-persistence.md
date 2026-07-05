# Knowledge Persistence: Memory (v2) / Cognee

Doctrine for when and how to search + save durable knowledge. `@`-imported by CLAUDE.md, so this file is always-loaded. Self-hosted-Cognee container operations (REST `localhost:8001`, ChromaDB, `docker compose cognee`, `bulk_ingest`, the deprecated `~/ingest/drop/` watcher) were retired with the move to the memory-v2 stack and are no longer here — the successor keeps the old MCP tool interface, so the search/save doctrine below is unchanged.

## Local write fallback (host-agnostic)

If a knowledge-WRITE tool (`cognify`, `save_interaction`, `remember`, `delete`, `prune`) is denied in this session, a local MCP may be registered on this host for writes — use the local equivalent instead (`mcp__cognee-local__cognify` / `mcp__cognee-local__save_interaction` / `mcp__memory-local__*`). READS (`search`, `recall`, `browse`) continue to use whichever connector is available (hosted or local). On hosts where the local servers are not registered, the connector write tools are allowed and this note is a no-op.

## "local" is NOT air-gapped — verify egress before routing work-sensitive data

`cognee-local` / `memory-local` (127.0.0.1) name the **MCP server location**, not the LLM/embedding backend. Graph extraction + embedding may call **external vendor APIs** (OpenAI, etc.) depending on container config, so "local" storage can still **egress content to a third party** on every write. Before routing any work-sensitive content (employer KPIs, product metrics, internal business data) through a local MCP:

1. Probe the actual egress:

   ```bash
   docker exec local-mcp-cognee-1 env | grep -iE 'LLM_(PROVIDER|ENDPOINT|MODEL)|EMBEDDING_(PROVIDER|ENDPOINT)|OPENAI|ANTHROPIC'
   ```

2. If any `*_ENDPOINT` points to a vendor API (`api.openai.com`, …), treat that MCP as equivalent to that vendor for data-sensitivity purposes — route work data through it only when the vendor is sanctioned for that data class, and **never** to a personal home-lab / personal Notion.
3. For structured data that only needs exact comparison (a KPI snapshot, a metrics diff), prefer a **local file (JSON)** — zero egress, exact diff, and the semantic graph adds nothing for fixed numbers.

The name `local` is not evidence of air-gap. Origin: 2026-06-19 kpi-delta-monitor loop — `docker exec env` showed `LLM_ENDPOINT=https://api.openai.com/v1`; routing Mercari KPI through it would have egressed to OpenAI. Snapshot moved to a local JSON file.

## Memory (unified v2 MCP)

Cross-project memory for user attributes, preferences, possessions, and durable facts. The claude.ai `memory` connector serves the unified v2 MCP (ElasticSearch + Voyage embeddings, hybrid BM25 + kNN recall). The old mem0 tool names (`add_memories` / `search_memory` / `list_memories`) are RETIRED — use:

- `recall(query, type?, top_k?, filters?)` — hybrid search over all memory (was `search_memory`). `type` optionally scopes to `fact` / `knowledge` / `episode`.
- `remember(content, type, tags?)` — persist a memory; `type` MUST be explicit: `fact` (atomic durable fact — the `add_memories` replacement), `knowledge` (a document/chunk), or `episode` (session summary).
- `browse(type?, filters?, sort?, limit?)` + `memory_stats()` — list + counts (was `list_memories`).
- `ingest(document, dataset, doc_key)` (upsert a whole document), `revise(id, content)`, `forget(id)`, `get(id)` — document/edit ops.

Async write model: a `fact` is written immediately as `raw`, then a keeper (on the es-memory host, `claude -p`) reconciles it (ADD/UPDATE/NOOP dedup) within a tick or two. Transparent to callers — keep saving; a just-remembered fact becomes searchable in its reconciled form shortly after.

### When to Search (memory)

Run `recall` in parallel with Cognee at conversation start. Always search when the topic relates to user attributes (possessions, preferences, body measurements).

### When to Save (memory)

Save immediately when user attributes are revealed during conversation — do not wait to be asked, via `remember(content, type='fact')`. Targets: body measurements, owned devices/gear, food preferences, riding style, workflow preferences, relationships/roles.

## Cognee Knowledge Graph

Cross-project knowledge store for technical knowledge, product reviews, business insights, and reference documents. Available via MCP tools: `search`, `cognify`, `save_interaction`. If Cognee MCP is not connected in this session, skip all Cognee operations silently.

### When to Search (READ)

Run a Cognee search **before** generating a response to the first message in a conversation. Also search before decisions on the same topic/product/tech, on errors (may be solved before), and for investment/business questions.

**No search needed**: trivial edits, typo fixes, and git operations only.

**Search type selection:**

| Need | search_type |
|------|-------------|
| Recommendations, relationships, why-questions | GRAPH_COMPLETION |
| Specific facts, error solutions, product specs | CHUNKS |
| Overview of a topic, product category summary | SUMMARIES |

Use `top_k=5` for focused queries, `top_k=15` for broad exploration.

### When to Save (WRITE)

When a research, review, or analysis task reaches a conclusion (summary or comparison table produced), save immediately **before** moving to the next task. Do not wait for the user to ask.

**Debugging sessions**: the save trigger is **root cause identification**, not task completion. When you identify the root cause of a non-obvious bug with confidence, save it immediately — before implementing the fix. The root cause and the failed hypotheses both have future value.

**`cognify` (durable insight)** for the lasting stuff: bug root-causes + fixes, architectural decisions + rationale, product reviews/comparisons, API gotchas/workarounds, infra patterns, cross-project conventions, user attributes/possessions/preferences. **`save_interaction` (light)** for troubleshooting steps, quick impressions, project setup notes. Short atomic user-attribute facts go to memory `remember(type='fact')` instead. **Never save** secrets/credentials/tokens, routine refactors, info already in README, or temporary state (branch/WIP).

### Save Format

Structure each `cognify` note as a self-contained block: Topic / Context (project, stack) / Problem / Solution / Why. (Adapt the labels for reviews — Rating/Pros/Cons/Verdict — or analyses — Findings/Recommendation/Risks.)

### Post-Save Verification

MCP `cognify` returns success even when the background pipeline fails silently. After a save, wait for background processing, then `search` (`search_type: CHUNKS`) using 2-3 key terms from the saved content. If results are empty, the save did not land — retry.

### Cognify Timeout Fallback

When a `cognify` MCP call returns a timeout (typically ~60s waiting on LLM extraction), do NOT silently drop the knowledge — the commit log is not a substitute for graph search. Two timeouts on the same content in one session = it won't ingest without intervention:

1. Write the structured note to `~/.claude/pending-cognify/<YYYY-MM-DD>-<topic-slug>.md` (same Save Format, full body — not abbreviated).
2. Add a TODO.md entry (project memory, or `~/.claude/pending-cognify/TODO.md`) with a concrete re-ingest note.
3. Do NOT block the current task on recovery — the fallback file is the durable artifact.
4. On next session start, drain `~/.claude/pending-cognify/*.md` before cognifying new content (the `knowledge-drain` skill automates this).

**Short content** (1-2 sentences, single user-attribute fact) → prefer memory `remember(type='fact')` (faster, different infra). Larger cross-session knowledge (debug pattern, architectural decision) belongs in cognify even if it waits for re-ingest. Origin: 2026-04-29 two cognify saves lost to back-to-back timeouts, invisible until re-ingested.

### PDF / Document Ingestion

Use the `/ingest-pdf` skill (PyPDF2 text extraction; image-based PDFs render each page via PyMuPDF and extract text via Claude vision). After ingest, verify with `search` (CHUNKS) on key terms; re-run if sparse. Use `/verify-cognee` for systematic gap audits (source-dir file list vs Cognee chunks).
