#!/usr/bin/env python3
"""Migrate Mem0/OpenMemory memories into the ES `memory-user` index.

Source: the running OpenMemory API (REST). Each memory's text is re-embedded
with OpenAI (text-embedding-3-small) and indexed into ES, tagged with an
A/B `category` (user-attr vs research-frag). Idempotent on re-run via a
content hash as the ES _id.

Usage:
  OPENMEMORY_URL=http://127.0.0.1:8765 MEM0_USER=shin1ohno \
  ES_URL=https://192.168.1.77:9200 ES_PASSWORD=... OPENAI_API_KEY=... \
  python3 migrate_mem0.py [--dry-run]

The OpenMemory list endpoint shape varies by version; this script tries the
documented v1 path and falls back to the MCP list. Confirm the count against
`list_memories` after the run.
"""

from __future__ import annotations

import os
import sys

import httpx

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "es-memory-mcp"))
import es_backend as be  # noqa: E402  (path injected above)

OPENMEMORY_URL = os.environ.get("OPENMEMORY_URL", "http://127.0.0.1:8765").rstrip("/")
DRY_RUN = "--dry-run" in sys.argv


def fetch_memories() -> list[dict]:
    """Return [{memory, created_at?}]. Tries the v1 REST list endpoint."""
    client = httpx.Client(timeout=30.0)
    for path in (f"/api/v1/memories/?user_id={be.MEM0_USER}",
                 f"/api/v1/memories?user_id={be.MEM0_USER}"):
        try:
            resp = client.get(f"{OPENMEMORY_URL}{path}")
            if resp.status_code == 200:
                data = resp.json()
                items = data.get("items", data) if isinstance(data, dict) else data
                out = []
                for it in items:
                    text = it.get("memory") or it.get("content") or it.get("text")
                    if text:
                        out.append({"memory": text,
                                    "created_at": it.get("created_at")})
                if out:
                    return out
        except Exception as exc:  # noqa: BLE001
            print(f"  list attempt {path} failed: {exc}", file=sys.stderr)
    raise SystemExit("Could not fetch memories — check OPENMEMORY_URL / endpoint shape.")


def main() -> None:
    be.ensure_indices()
    mems = fetch_memories()
    print(f"Fetched {len(mems)} memories from OpenMemory.")
    if DRY_RUN:
        for m in mems[:10]:
            print(f"  [{be._classify_category(m['memory']) if hasattr(be, '_classify_category') else '?'}] {m['memory'][:80]}")
        print("(dry-run — nothing indexed)")
        return

    # Local classifier mirrors server.py (kept here to avoid importing the MCP app).
    research_markers = ("api", "version", "released", "cookbook", "dataset",
                        "proposal", "audit", "http", "pr #", "github")

    def classify(fact: str) -> str:
        low = fact.lower()
        return "research-frag" if any(m in low for m in research_markers) else "user-attr"

    docs = []
    texts = [m["memory"] for m in mems]
    vectors = be.embed(texts)
    now = be._now_iso()
    for m, vec in zip(mems, vectors):
        h = be.content_hash(m["memory"])
        docs.append({
            "_id": h,
            "memory": m["memory"],
            "embedding": vec,
            "user_id": be.MEM0_USER,
            "category": classify(m["memory"]),
            "hash": h,
            "created_at": m.get("created_at") or now,
            "updated_at": now,
        })
    n = be.bulk_index(be.MEMORY_INDEX, docs)
    print(f"Indexed {n} memories into ES `{be.MEMORY_INDEX}`.")


if __name__ == "__main__":
    main()
