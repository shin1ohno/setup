#!/usr/bin/env python3
"""Migrate Cognee knowledge chunks from RDS pgvector into the ES `knowledge`
index.

Strategy: extract chunk TEXT (+ a best-effort dataset label) from the Cognee
Postgres schema and RE-EMBED with OpenAI before indexing. Re-embedding (rather
than copying the stored pgvector bytes) sidesteps any pgvector<->dense_vector
binary-format conversion and keeps the embedding model identical
(text-embedding-3-small, 1536-dim). Cost is a few hundred cheap embedding
calls for the snowboard catalogs + cost reports.

SCHEMA NOTE — Cognee's table layout is version-specific and was NOT verified
live at authoring time (DB unreachable from the dev host). This script
DISCOVERS the text-bearing table at runtime: it scans for tables holding a
`text`/`content`/`chunk` column and a `vector`-typed column, prints what it
found, and (unless --apply) stops so you can confirm before indexing.

Usage:
  DATABASE_URL=postgresql://cognee:...@<rds-host>:5432/cognee \
  ES_URL=https://192.168.1.77:9200 ES_PASSWORD=... OPENAI_API_KEY=... \
  python3 migrate_cognee.py            # discovery only (safe)
  ... python3 migrate_cognee.py --apply  # actually re-embed + index

Requires psycopg2-binary (pip install psycopg2-binary).
"""

from __future__ import annotations

import os
import sys

import psycopg2

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "es-memory-mcp"))
import es_backend as be  # noqa: E402

DATABASE_URL = os.environ["DATABASE_URL"]
APPLY = "--apply" in sys.argv
BATCH = 100

TEXT_COL_CANDIDATES = ("text", "content", "chunk", "chunk_text", "raw_text")
DATASET_COL_CANDIDATES = ("dataset", "dataset_name", "node_set", "belongs_to_set")


def discover_chunk_tables(cur) -> list[tuple[str, str, str | None]]:
    """Return [(table, text_col, dataset_col_or_None)] for tables that have a
    text column and at least one vector column."""
    cur.execute("""
        SELECT table_name, column_name, data_type, udt_name
        FROM information_schema.columns
        WHERE table_schema = 'public'
        ORDER BY table_name, ordinal_position
    """)
    cols: dict[str, list[tuple[str, str, str]]] = {}
    for table, col, dtype, udt in cur.fetchall():
        cols.setdefault(table, []).append((col, dtype, udt))

    found = []
    for table, columns in cols.items():
        names = {c[0].lower() for c in columns}
        has_vector = any(udt == "vector" or dtype == "USER-DEFINED"
                         for _, dtype, udt in columns)
        text_col = next((c for c in TEXT_COL_CANDIDATES if c in names), None)
        if text_col and has_vector:
            dataset_col = next((c for c in DATASET_COL_CANDIDATES if c in names), None)
            found.append((table, text_col, dataset_col))
    return found


def migrate_table(cur, table: str, text_col: str, dataset_col: str | None) -> int:
    sel_cols = f'"{text_col}"' + (f', "{dataset_col}"' if dataset_col else "")
    cur.execute(f'SELECT {sel_cols} FROM "{table}"')
    rows = cur.fetchall()
    print(f"  {table}: {len(rows)} rows")
    total = 0
    for i in range(0, len(rows), BATCH):
        batch = rows[i:i + BATCH]
        texts = [r[0] for r in batch if r[0]]
        if not texts:
            continue
        vectors = be.embed(texts)
        now = be._now_iso()
        docs = []
        for (row, vec) in zip([r for r in batch if r[0]], vectors):
            dataset = row[1] if dataset_col and len(row) > 1 else "main_dataset"
            docs.append({
                "_id": be.content_hash(row[0]),
                "text": row[0],
                "embedding": vec,
                "dataset": str(dataset) if dataset else "main_dataset",
                "summary": "",
                "source_doc": f"cognee:{table}",
                "chunk_index": 0,
                "created_at": now,
                "metadata": {"migrated_from": "cognee_pgvector"},
            })
        total += be.bulk_index(be.KNOWLEDGE_INDEX, docs)
        print(f"    indexed {total}/{len(rows)}")
    return total


def main() -> None:
    be.ensure_indices()
    conn = psycopg2.connect(DATABASE_URL)
    cur = conn.cursor()
    tables = discover_chunk_tables(cur)
    if not tables:
        raise SystemExit("No text+vector table found. Inspect the schema manually "
                         "(\\dt in psql) and adjust *_COL_CANDIDATES.")
    print("Discovered chunk tables (table, text_col, dataset_col):")
    for t in tables:
        print(f"  {t}")
    if not APPLY:
        print("\n(discovery only — re-run with --apply to re-embed + index)")
        return
    grand = 0
    for table, text_col, dataset_col in tables:
        grand += migrate_table(cur, table, text_col, dataset_col)
    print(f"\nMigrated {grand} chunks into ES `{be.KNOWLEDGE_INDEX}`.")


if __name__ == "__main__":
    main()
