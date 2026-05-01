---
name: ingest-to-cognee
description: |
  Use this skill when the user wants to ingest a file or directory into the Cognee knowledge graph — triggers are "ingest this PDF into Cognee", "add these to my knowledge graph", "save this document for future search", "load this catalog into memory", or any explicit "Cognee + ingest" framing. Handles text files, text-PDFs (via Cowork's built-in pdf skill), and image-PDFs (page render + Claude vision). Generates unique filenames to avoid data_id collisions, calls Cognee MCP `cognify`, and verifies search returns the ingested content. Requires Cognee MCP. Distinct from Cowork's built-in `pdf` skill, which handles PDF manipulation but not knowledge-graph ingestion.
---

# Ingest to Cognee Skill

Add files to the Cognee knowledge graph with text-extraction fallbacks and post-ingest verification.

## Prerequisites

- Cognee MCP connected. If absent: "Cognee MCP is not connected. Connect it and retry."

## Argument Parsing

User's message: `<file or directory path> [dataset_name]`

- File or directory: required (workspace folder path)
- Dataset name: optional, defaults to `<category>_<basename>` derived from the source path

If a directory is given, recurse and process each file.

## Workflow

### Step 1: Text Extraction Triage

For each file:

| File type | Method |
|---|---|
| `.txt`, `.md`, `.html` | Read directly |
| `.pdf` (text-based, ≥ pages × 100 chars extractable) | Cowork `pdf` skill → extract text |
| `.pdf` (image-based, < pages × 100 chars) | Cowork `pdf` skill → render pages as PNG → Claude vision reads each page → assemble structured Markdown |
| `.docx` | Cowork `docx` skill → extract text |
| Other | Skip with a warning |

For image-based PDFs, the markdown should preserve all readable structured content (model names, prices, specs, categories, dates).

### Step 2: Filename Uniqueness

Cognee's `/api/v1/add` deterministically generates `data_id` from filename. Duplicate filenames across uploads collide.

Build a unique filename: `<category>_<source-name>_<detail>_text.txt` (e.g., `snowboard_jones_2627_catalog_text.txt`). Stage the extracted text under this name in the workspace `outputs/` directory.

### Step 3: Cognify

Call Cognee MCP `cognify` with:

- The staged text content (or file path if MCP supports file input)
- Dataset name from arguments or auto-derived

Allow up to 10 minutes for completion (large image-PDFs need vision processing time).

### Step 4: Verify

After `cognify` returns:

1. Wait for background processing (Cognee runs cognify asynchronously)
2. Use Cognee MCP `search` (CHUNKS, key terms from the ingested content)
3. If results are empty, inspect Cognee logs (the user will need to run `docker compose logs cognee --tail 30` if they have local Cognee)
4. Re-run cognify if needed

### Step 5: Report

Output a summary:

```
| File | Method | Dataset | Status | Verify search |
|---|---|---|---|---|
| jones_2627_catalog.pdf | text-PDF | snowboard_jones_2627 | done | 3 chunks returned |
```

## Notes

- Watcher (`~/ingest/drop/`) is deprecated — uses ingest-mid-write and causes data_id collisions
- Container restart can lose internal `text_<hash>.txt` files. If `cognify` returns 409, restart Cognee and re-upload
- Prefer per-domain datasets (e.g., `snowboard_<brand>`) over a single `main_dataset` — enables independent rebuild

## When NOT to use

- The user wants to extract text without saving to Cognee → use the `pdf` skill alone
- The user wants to manipulate a PDF (split / merge / form fill) → use the `pdf` skill alone
- The target file is already in Cognee — verify first via `verify-cognee` skill
