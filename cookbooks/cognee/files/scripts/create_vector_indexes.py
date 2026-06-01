#!/usr/bin/env python3
"""Idempotently create pgvector HNSW indexes on every vector column in the
cognee database.

Why this exists
---------------
cognee's PGVectorAdapter.create_vector_index() only calls create_collection()
(a CREATE TABLE) — it never builds an ANN index. Every similarity search
therefore runs a sequential scan computing `vector <=> query` for every row.
On the shared db.t4g.micro RDS this measured ~4.9s for the Entity_name table
(7036 rows) even fully cached — the throttled burstable CPU is the bottleneck.
An HNSW index turns that into an Index Scan (~1.5ms).

Design
------
- Runs INSIDE the cognee container (DB creds come from the container env:
  DB_HOST / DB_PASSWORD / DB_NAME). Invoked via `docker exec -i ... python3 -`.
- Discovers vector columns dynamically from pg_attribute (typname='vector')
  so new collections added by future cognify runs get indexed on the next
  mitamae apply.
- CREATE INDEX CONCURRENTLY + IF NOT EXISTS:
  * CONCURRENTLY → no write lock; safe to run against the production RDS that
    mem0 also uses.
  * IF NOT EXISTS → idempotent; cheap no-op on re-runs.
- Drops and rebuilds any index left INVALID by a previously-interrupted
  CONCURRENTLY build (IF NOT EXISTS would otherwise skip the broken index).
"""

import os
import sys

try:
    import psycopg2
except ImportError:  # pragma: no cover - container always ships psycopg2
    sys.stderr.write("psycopg2 not available in container; skipping index creation\n")
    sys.exit(0)

HOST = os.environ.get("DB_HOST")
PORT = int(os.environ.get("DB_PORT", "5432"))
USER = os.environ.get("DB_USERNAME", "cognee")
PASSWORD = os.environ.get("DB_PASSWORD")
DBNAME = os.environ.get("DB_NAME", "cognee")

if not HOST or not PASSWORD:
    sys.stderr.write("DB_HOST/DB_PASSWORD not set in environment; skipping\n")
    sys.exit(0)


def main() -> int:
    conn = psycopg2.connect(
        host=HOST, port=PORT, user=USER, password=PASSWORD,
        dbname=DBNAME, connect_timeout=15,
    )
    conn.autocommit = True  # CONCURRENTLY cannot run inside a transaction block
    cur = conn.cursor()

    cur.execute(
        """
        SELECT c.relname
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_type  t ON t.oid = a.atttypid
        WHERE t.typname = 'vector' AND c.relkind = 'r'
        ORDER BY c.relname;
        """
    )
    tables = [r[0] for r in cur.fetchall()]
    if not tables:
        print("no vector tables found yet (cognee not yet populated) — nothing to index")
        return 0

    created = skipped = rebuilt = 0
    for tbl in tables:
        idx = f"idx_{tbl}_vec_hnsw".lower()

        # Rebuild an index left INVALID by an interrupted CONCURRENTLY build.
        cur.execute(
            """
            SELECT i.indisvalid
            FROM pg_class c
            JOIN pg_index i ON i.indexrelid = c.oid
            WHERE c.relname = %s;
            """,
            (idx,),
        )
        row = cur.fetchone()
        if row is not None and row[0] is False:
            print(f"{tbl}: dropping INVALID index {idx} (interrupted build)")
            cur.execute(f'DROP INDEX CONCURRENTLY IF EXISTS "{idx}";')
            rebuilt += 1

        before = cur.rowcount
        cur.execute(
            f'CREATE INDEX CONCURRENTLY IF NOT EXISTS "{idx}" '
            f'ON "{tbl}" USING hnsw (vector vector_cosine_ops);'
        )
        # statusmessage is "CREATE INDEX" whether or not it already existed;
        # distinguish via a follow-up existence check is overkill — just log.
        if cur.statusmessage == "CREATE INDEX":
            print(f"{tbl}: index {idx} present (created or already existed)")
            created += 1
        else:
            skipped += 1

    print(
        f"done: {len(tables)} vector tables, {created} indexes ensured, "
        f"{rebuilt} invalid rebuilt"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
