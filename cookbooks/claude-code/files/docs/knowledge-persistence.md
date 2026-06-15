# Knowledge Persistence: Mem0 / Cognee Details

## Local write fallback (host-agnostic)

If a knowledge-WRITE tool (`cognify`, `save_interaction`, `add_memories`, `delete`, `prune`) is denied in this session, a local MCP is configured on this host for writes — use the local equivalent instead: `mcp__cognee-local__cognify` / `mcp__cognee-local__save_interaction` / `mcp__memory-local__add_memories`. READS (`search`, `search_memory`, `list_data`, `list_memories`) continue to use whichever connector is available (hosted or local). On hosts where the local servers are not registered, the connector write tools are allowed and this note is a no-op.

## Mem0

Cross-project memory for user attributes, preferences, and possessions.
Available via MCP tools: `add_memories`, `search_memory`, `list_memories`.

### When to Search

Run search_memory in parallel with Cognee at conversation start. Always search when the topic relates to user attributes (possessions, preferences, body measurements).

### When to Save

Save immediately when user attributes are revealed during conversation — do not wait to be asked. Targets: body measurements, owned devices/gear, food preferences, riding style, workflow preferences, relationships/roles.

## Cognee Knowledge Graph

Cross-project knowledge store for technical knowledge, product reviews, business insights, and reference documents.
Available via MCP tools: `search`, `cognify`, `save_interaction`, `list_data`.
If Cognee MCP is not connected in this session, skip all Cognee operations silently.

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

**Debugging sessions**: the save trigger is **root cause identification**, not task completion. When you identify the root cause of a non-obvious bug with confidence, save it to Cognee immediately — before implementing the fix. The root cause and the failed hypotheses both have future value.

**`cognify` (durable insight)** for the lasting stuff: bug root-causes + fixes, architectural decisions + rationale, product reviews/comparisons, API gotchas/workarounds, infra patterns, cross-project conventions, user attributes/possessions/preferences (save proactively when revealed). **`save_interaction` (light)** for troubleshooting steps, quick impressions, project setup notes. **Never save** secrets/credentials/tokens, routine refactors, info already in README, or temporary state (branch/WIP).

### Save Format

Structure each `cognify` note as a self-contained block: Topic / Context (project, stack) / Problem / Solution / Why. (Adapt the labels for reviews — Rating/Pros/Cons/Verdict — or analyses — Findings/Recommendation/Risks.)

### Post-Cognify Verification

After every `cognify` or `save_interaction` call via MCP, verify the data was actually persisted:

1. Wait for background processing (cognify runs asynchronously)
2. Search with `search_type: CHUNKS` using 2-3 key terms from the saved content
3. If results are empty, check Cognee container logs for errors (`docker compose logs cognee --tail 20`)
4. If the error is `'NoneType' object has no attribute 'keys'`, this is a ChromaDB client/server version mismatch — see Troubleshooting below

This applies to all cognify calls, not just PDF ingestion. MCP cognify returns success even when the background pipeline fails silently.

### Cognify Timeout Fallback

When a `cognify` MCP call returns a timeout error (typically after ~60s waiting for the LLM extraction step), do NOT silently drop the knowledge — the commit log is not a substitute for graph search. Two cognify timeouts in the same session = the graph won't ever ingest these findings without manual intervention.

**Fallback procedure** when cognify times out twice on the same content:

1. Write the structured note to `~/.claude/pending-cognify/<YYYY-MM-DD>-<topic-slug>.md` using the same format from "Save Format" above (preserved cognify body, not abbreviated)
2. Add a TODO.md entry in the project memory (or `~/.claude/pending-cognify/TODO.md` if no project context) with the concrete re-ingest command:
   ```
   ## Re-ingest pending cognify: <topic>
   **File**: ~/.claude/pending-cognify/2026-04-29-cbuuid-uniffi.md
   **Command**:
       cat ~/.claude/pending-cognify/2026-04-29-cbuuid-uniffi.md | \
         curl -s -X POST http://localhost:8001/api/v1/add \
         -H "Authorization: Bearer $TOKEN" \
         -F "data=@-" -F "datasetName=main_dataset"
   ```
3. Do NOT block the current task on Cognee recovery — the fallback file is the durable artifact
4. On next session start, before running `cognify` for new content, drain `~/.claude/pending-cognify/*.md` first

**When to use Mem0 fallback instead**: if the content is short (1-2 sentences, single fact about user attribute or possession), the Mem0 `add_memories` MCP tool is faster and has different infrastructure. Cross-session knowledge that's larger (debug pattern, architectural decision, multi-paragraph rationale) belongs in cognify even if it has to wait for re-ingest.

Origin: 2026-04-29 two cognify saves lost to back-to-back timeouts, invisible to graph search until re-ingested.

### Ingestion Method Selection

| Data | Method | When |
|------|--------|------|
| Single insight (< 500 words) | `cognify` MCP tool | During conversation |
| Interaction log | `save_interaction` MCP tool | End of meaningful exchange |
| PDF/document | `/ingest-pdf` skill | When user provides a file |
| Large batch (10+ files) | `bulk_ingest.py` via docker | One-time imports |

### PDF and Document Ingestion

Use the `/ingest-pdf` skill. Manual procedure if needed:

1. Attempt text extraction with PyPDF2. If extracted characters < pages × 100, classify as image-based PDF
2. Image-based PDF: render each page as an image with PyMuPDF (DPI=200) → extract text via Claude's vision
3. Upload with a unique filename via REST API `POST /api/v1/add` (use `datasetName` parameter to create a dedicated dataset)
4. `POST /api/v1/cognify` (specify target with `datasets` parameter)
5. Verify ingestion with MCP `search` (`GRAPH_COMPLETION`)
6. **Verification loop**: after cognify returns, wait for background processing to complete (check `cognify_status`), then search for key terms from the ingested document using CHUNKS mode. If results are empty or sparse, re-run cognify
7. **Gap audit**: compare source directory file list against Cognee search results for each group/brand. Re-ingest any files with zero matching chunks. Use `/verify-cognee` skill for systematic audits

**Watcher (`~/ingest/drop/`) is deprecated**: it ingests files mid-write and causes data_id collisions on duplicate filenames. Use the REST API for uploads instead.

### Cognee Operational Notes

- **Filename uniqueness**: `/api/v1/add` generates data_id deterministically from the filename. Duplicate filenames are treated as the same record — use unique names like `<category>_<name>_<detail>_text.txt`
- **Dataset isolation**: prefer per-domain datasets (e.g., `snowboard_<brand>`) over aggregating into main_dataset. Enables independent rebuilds on container failure
- **Container restart risk**: restarts can lose internal `text_<hash>.txt` files. If cognify returns 409, this is the cause. Fix by re-uploading data and re-running cognify
- **API info**: Base URL `http://localhost:8001`, auth via `POST /api/v1/auth/login` (form: `username=default_user@example.com&password=default_password`)

### Troubleshooting

**Cognify succeeds but search returns no results:**
1. Check cognee container logs: `docker compose -f ~/deploy/cognee/docker-compose.yml logs cognee --tail 30`
2. Look for `'NoneType' object has no attribute 'keys'` in ChromaDBAdapter — this means client/server version mismatch
3. Compare versions: `docker compose exec cognee python3 -c "import chromadb; print(chromadb.__version__)"` vs `docker compose images chromadb`
4. Fix: update ChromaDB server image in `cookbooks/cognee/files/docker-compose.yml` to match the client version, then `docker compose up -d chromadb && docker compose restart cognee cognee-mcp`

**REST API add returns 500 "datasetName must be provided":**
- Cognee 0.5.8+ requires `datasetName` in the add request body
- MCP cognify handles this automatically via the cognee_client's default `dataset_name="main_dataset"`
- For direct REST API calls: use multipart form with `-F "data=@file.txt" -F "datasetName=main_dataset"`
