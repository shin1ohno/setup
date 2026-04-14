---
name: ingest-batch
description: Batch-ingest files into Cognee with automatic grouping, parallel sub-agents, and verification.
user-invocable: true
allowed-tools: ["Bash", "Agent", "Glob", "Read"]
argument-hint: "<source_dir> [naming_pattern]"
---

# Ingest Batch Skill

## Purpose

Ingest a directory of files into Cognee knowledge graph, automatically grouping by brand/category, deduplicating, and verifying completeness.

## Argument Parsing

`$ARGUMENTS` must contain:
- `source_dir` (required): path to source files
- `naming_pattern` (optional): dataset naming template (default: `<category>_<brand>_<season>`)

## Workflow

### Step 1: Source Assessment

1. List all files in source_dir
2. Group files by brand/category (infer from filename patterns)
3. Detect duplicates: compare file sizes, flag identical files
4. Classify each file's extraction method:
   - `.txt` / `.md` → direct text chunking
   - `.pdf` (text-based) → PyMuPDF text extraction
   - `.pdf` (image-based, < 100 chars/page) → Vision API extraction
5. Exclude test files and known duplicates
6. Present grouping plan to user via AskUserQuestion

### Step 2: Parallel Ingestion

For each group (1 agent = 1 group):
1. Launch background sub-agent
2. Agent extracts text using the classified method
3. Agent chunks text (paragraph-based for short docs, fixed-size for long docs)
4. Agent calls MCP `cognify` with dataset name from naming pattern
5. Agent reports success/failure

All agents launch in parallel in a single message.

### Step 3: Progress Tracking

Show progress table, update as agents complete:

```
| Group           | Files | Method    | Status         |
|-----------------|-------|-----------|----------------|
| jones_2627      | 2     | PyMuPDF   | done           |
| nidecker_2627   | 1     | Vision    | processing...  |
```

### Step 4: Verification

After all agents complete, invoke `/verify-cognee` workflow:
1. Search each group in Cognee (CHUNKS mode)
2. Report any gaps
3. Offer to re-ingest failures

## Agent Self-Recovery

Each sub-agent should handle errors autonomously:
- `ModuleNotFoundError: requests` → fall back to `urllib.request`
- PyMuPDF extraction empty → escalate to Vision API
- MCP cognify timeout → retry once, then report failure
- Only escalate to user after 2+ fallback attempts fail

## Notes

- Use MCP `cognify` exclusively — REST API `POST /api/v1/add` silently fails
- Dataset naming: `<category>_<brand>_<detail>` (e.g., `snowboard_jones_2627`)
- Cognify is async: graph construction happens in background after API returns
- Large PDFs (>50MB) may take significant time and LLM cost for Vision extraction
