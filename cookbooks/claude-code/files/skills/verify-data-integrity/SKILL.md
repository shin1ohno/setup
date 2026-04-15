---
name: verify-data-integrity
description: Check data integrity across Cognee's PostgreSQL, ChromaDB, and graph DB. Detects empty datasets, orphan vectors, stuck pipelines, and test data pollution.
user-invocable: true
argument-hint: "[cognee|mem0|all]"
---

# Data Integrity Verification Skill

## Purpose

Detect inconsistencies between Cognee's storage layers (PostgreSQL metadata, ChromaDB vectors, kuzu graph) and report findings with a concrete fix plan.

## Argument Parsing

`$ARGUMENTS` selects the target system. Default: `cognee`.

| Argument | Scope |
|----------|-------|
| `cognee` | Cognee PostgreSQL + ChromaDB + graph |
| `mem0` | mem0/OpenMemory PostgreSQL |
| `all` | Both systems |

## Workflow

### Step 1: Connection Verification

Verify connectivity to all storage layers before running checks:

```
- Cognee PostgreSQL: via docker exec or direct psql
- ChromaDB: via docker exec python3 + chromadb client
- mem0 PostgreSQL: via API endpoint /api/v1/stats/
```

If any connection fails, report the failure and skip that layer's checks.

### Step 2: Cognee Integrity Checks

Run the following checks in parallel (3 sub-agents or sequential queries):

#### Check A — Empty Datasets

```sql
SELECT ds.name, COUNT(dd.data_id) as data_count
FROM datasets ds
LEFT JOIN dataset_data dd ON ds.id = dd.dataset_id
GROUP BY ds.name
ORDER BY ds.name;
```

Flag datasets with 0 data items. These are "shell" datasets — the metadata exists but no data is linked.

#### Check B — PostgreSQL vs ChromaDB Vector Count

Compare:
- PostgreSQL: `SELECT COUNT(*) FROM data` (source documents)
- ChromaDB: `DocumentChunk_text` collection count (indexed vectors)
- ChromaDB: `Entity_name` collection count
- ChromaDB: `TextSummary_text` collection count

Expected relationship: ChromaDB DocumentChunk count >= PostgreSQL data count (one document produces multiple chunks). Flag if ChromaDB has 0 vectors or PostgreSQL data count is 0.

#### Check C — Stuck Pipeline Runs

```sql
SELECT status, COUNT(*)
FROM pipeline_runs
GROUP BY status
ORDER BY count DESC;
```

Flag if INITIATED count > COMPLETED count (pipelines that started but never finished).

#### Check D — Test Data Pollution

Query ChromaDB `DocumentChunk_text` collection and scan for test patterns:

```python
# Patterns indicating test data
test_patterns = ['test ingest', 'e2e test', 'cognee_test', 'compat_test']
```

Report count and IDs of test data vectors found in production collections.

#### Check E — Orphan Data

```sql
-- Data not linked to any dataset
SELECT d.id, d.name FROM data d
LEFT JOIN dataset_data dd ON d.id = dd.data_id
WHERE dd.dataset_id IS NULL;
```

### Step 3: mem0 Integrity Checks

#### Check F — Memory Count and Health

- Call `/api/v1/stats/?user_id=<user>` and verify response
- Check for orphan memories (memories without valid app_id)

### Step 4: Report

Present findings as a table:

```
| Check | Status | Details |
|-------|--------|---------|
| A. Empty datasets | ⚠️ 11 found | snowboard_* datasets have 0 data items |
| B. PG/ChromaDB sync | ✓ OK | 16 docs → 107 chunks |
| C. Stuck pipelines | ⚠️ 361 stuck | INITIATED without COMPLETED |
| D. Test pollution | ⚠️ 5 vectors | test ingest + E2E test data |
| E. Orphan data | ✓ OK | No orphans |
| F. mem0 health | ✓ OK | 13 memories |
```

### Step 5: Fix Plan

For each issue found, propose a concrete fix:

| Issue | Fix | Risk |
|-------|-----|------|
| Empty datasets | Delete shell datasets or re-ingest source data | Low — empty datasets have no data to lose |
| Stuck pipelines | `DELETE FROM pipeline_runs WHERE status = 'INITIATED' AND id NOT IN (...)` | Low — cleanup stale records |
| Test pollution | Delete test vectors from ChromaDB collections by ID | Low — test data is not production data |
| PG/ChromaDB desync | Re-run cognify for affected datasets | Medium — may take time, verify after |

Present the fix plan for user review before executing any destructive operations.

## Principles

- **Read-only first**: all checks are read-only queries. No modifications without explicit user approval
- **Report with fix plan**: never report findings without actionable next steps
- **Verify after fix**: after applying any fix, re-run the affected checks to confirm resolution
