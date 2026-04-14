---
name: verify-cognee
description: Compare source directory against Cognee datasets to find and fill ingestion gaps.
user-invocable: true
allowed-tools: ["Bash", "Agent", "Glob", "Read"]
argument-hint: "[source_dir] [dataset_prefix]"
---

# Verify Cognee Skill

## Purpose

Systematically compare a source directory against Cognee knowledge graph contents, report gaps, and optionally re-ingest missing files.

## Argument Parsing

`$ARGUMENTS` may contain:
- `source_dir`: path to source files (default: `~/deploy/cognee/ingest/drop/.done/`)
- `dataset_prefix`: filter datasets by prefix (e.g., `snowboard_` to check only snowboard brands)

## Workflow

### Step 1: Inventory Source Files

1. List all files in the source directory
2. Group by brand/category using filename patterns
3. Identify and flag duplicates (same size = likely identical)
4. Exclude test files (test*.md, test*.txt)
5. Output: file inventory table with grouping

### Step 2: Query Cognee Datasets

For each brand/category group:
1. Use MCP `search` (CHUNKS mode, top_k=3) with the brand name as query
2. Record whether results contain content from that brand's files
3. Use MCP `list_data` to check dataset existence

### Step 3: Gap Report

Output a comparison table:

```
| Brand/Category | Source Files | Cognee Status | Action Needed |
|---------------|-------------|---------------|---------------|
| jones         | 2 files     | OK (3 chunks) | none          |
| nidecker      | 1 file      | MISSING       | re-ingest     |
```

### Step 4: User Decision

Use AskUserQuestion to ask which gaps to fill (multiSelect).

### Step 5: Re-ingest (if requested)

For each gap to fill:
1. Evaluate source file type (text vs text-PDF vs image-PDF)
2. Launch 1 background sub-agent per brand (parallel)
3. Each agent: extract text → chunk → MCP cognify
4. After all agents complete, re-run Step 2-3 for verification

## Notes

- MCP `cognify` is the reliable ingestion path. REST API `POST /api/v1/add` returns 200 but silently fails
- Image-based PDFs (< 100 chars per page): use PyMuPDF for page rendering → Claude vision for text extraction
- Text-based PDFs: use PyMuPDF text extraction directly
- Text files: direct chunking (split by paragraphs or fixed size)
- Always verify after ingestion — cognify processes asynchronously in background
