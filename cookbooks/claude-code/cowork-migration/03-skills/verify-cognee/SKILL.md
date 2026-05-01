---
name: verify-cognee
description: |
  Use this skill when the user wants to verify Cognee knowledge graph completeness or detect ingestion gaps — triggers are "/verify-cognee", "check what's in Cognee", "is my data ingested", "find ingestion gaps", "compare files against Cognee", or after any batch ingest where the user is unsure whether everything landed. Inventories source files, queries Cognee per-group, produces a gap table, and (with user consent) re-ingests missing content. Requires Cognee MCP to be connected. Skip if Cognee MCP is not in this session — surface that fact instead of failing silently.
---

# Verify Cognee Skill

Compare a source directory against Cognee datasets to find and fill ingestion gaps.

## Prerequisites

- Cognee MCP must be connected. If not, abort with: "Cognee MCP is not connected in this session. Connect it from the MCP tab and retry."

## Argument Parsing

The user's message may include:

- `source_dir` — path to source files (default: ask via AskUserQuestion)
- `dataset_prefix` — filter datasets by prefix (e.g., `snowboard_`)

If absent, AskUserQuestion to clarify.

## Workflow

### Step 1: Inventory Source Files

1. List all files in the source directory (workspace folder if accessible)
2. Group by brand / category using filename patterns
3. Identify and flag duplicates (same size = likely identical)
4. Exclude test files (`test*.md`, `test*.txt`)
5. Output: file inventory table grouped

### Step 2: Query Cognee Datasets

For each group:

1. Use Cognee MCP `search` (CHUNKS mode, top_k=3) with the brand / category as query
2. Record whether results contain content from that brand's files
3. Use Cognee MCP `list_data` to confirm dataset existence

### Step 3: Gap Report

```
| Brand / Category | Source Files | Cognee Status | Action Needed |
|---|---|---|---|
| jones | 2 files | OK (3 chunks) | none |
| nidecker | 1 file | MISSING | re-ingest |
```

### Step 4: User Decision

AskUserQuestion (multiSelect) for which gaps to fill.

### Step 5: Re-ingest (if requested)

For each gap:

1. Identify file type (text / text-PDF / image-PDF)
2. Use the `ingest-to-cognee` skill (or Cowork's built-in `pdf` skill for PDF text extraction, then Cognee `cognify`)
3. After all ingest jobs finish, re-run Step 2 - 3 for verification

## Notes

- Cognee `cognify` is the reliable ingestion path. Direct REST API `POST /api/v1/add` returns 200 but can silently fail
- Image-based PDFs (< 100 chars per page): use the `pdf` skill for page rendering, then Claude vision for text extraction
- Always verify after ingestion — `cognify` runs asynchronously
