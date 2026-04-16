# Knowledge Persistence: Mem0 / Cognee Details

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

Run a Cognee search **before** generating a response to the first message in a conversation.

When to search:
1. **Conversation start**: the first message involving a non-trivial task
2. **Before decisions**: past decisions, reviews, or evaluations on the same topic/product/technology
3. **Product or tool discussions**: existing reviews, comparisons, recommendations
4. **On errors**: error messages or patterns — may have been solved before
5. **Investment or business questions**: past analyses, market data, recommendations on similar topics

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

**Debugging sessions**: the save trigger is **root cause identification**, not task completion. When you identify the root cause of a non-obvious bug with confidence, save it to Cognee immediately — before implementing the fix. Debugging sessions often involve multiple hypothesis-test cycles; the root cause and the failed hypotheses both have future value.

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

### Post-Cognify Verification

After every `cognify` or `save_interaction` call via MCP, verify the data was actually persisted:

1. Wait for background processing (cognify runs asynchronously)
2. Search with `search_type: CHUNKS` using 2-3 key terms from the saved content
3. If results are empty, check Cognee container logs for errors (`docker compose logs cognee --tail 20`)
4. If the error is `'NoneType' object has no attribute 'keys'`, this is a ChromaDB client/server version mismatch — see Troubleshooting below

This applies to all cognify calls, not just PDF ingestion. MCP cognify returns success even when the background pipeline fails silently.

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
