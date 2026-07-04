#!/usr/bin/env python3
"""Migrate the OLD es-memory indices into the memory-v2 index family.

Source (old, 1536-dim OpenAI vectors):
  * ``knowledge``   -> ``memory-knowledge``  (chunk docs)
  * ``memory-user`` -> ``memory-fact``       (atomic facts)

Old vectors CANNOT be copied: v2 uses Voyage ``voyage-3-large`` at **1024**
dims (old = 1536), so every doc's text is RE-EMBEDDED with Voyage before it is
written. Idempotent: ``dest _id = source _id`` so a re-run overwrites in place
(no duplicate rows, safe to interrupt and resume).

Contract references: memory-v2-contract §1 (index fields) + §2a (env names).

Usage (env per contract §2a):
    ES_URL=https://192.168.1.77:9200 ES_USER=elastic ES_PASSWORD=... \
    ES_VERIFY_CERTS=false \
    VOYAGE_API_KEY=... VOYAGE_ENDPOINT=https://api.voyageai.com/v1 \
    EMBEDDING_MODEL=voyage-3-large EMBEDDING_DIMENSIONS=1024 \
      python3 migrate_v2.py            # DRY-RUN (default): scroll + count, no writes
      python3 migrate_v2.py --apply    # re-embed + bulk index into v2
      python3 migrate_v2.py --apply --only fact   # migrate a single family

Optional overrides:
    SRC_KNOWLEDGE_INDEX (default "knowledge")
    SRC_MEMORY_INDEX    (default "memory-user")
    KNOWLEDGE_INDEX     (dest, default "memory-knowledge")
    FACT_INDEX          (dest, default "memory-fact")

Self-contained on purpose: it does NOT import the v2 es_backend (which reads
env at import time and would confuse the 1536->1024 boundary). httpx is the
only third-party dependency (present in the server venv).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time

import httpx

# --------------------------------------------------------------------------- #
# Env (contract §2a names)
# --------------------------------------------------------------------------- #
ES_URL = os.environ["ES_URL"].rstrip("/")
ES_USER = os.environ.get("ES_USER", "elastic")
ES_PASSWORD = os.environ["ES_PASSWORD"]
ES_VERIFY = os.environ.get("ES_VERIFY_CERTS", "false").lower() == "true"

VOYAGE_API_KEY = os.environ.get("VOYAGE_API_KEY", "")
VOYAGE_ENDPOINT = os.environ.get("VOYAGE_ENDPOINT", "https://api.voyageai.com/v1").rstrip("/")
EMBEDDING_MODEL = os.environ.get("EMBEDDING_MODEL", "voyage-3-large")
EMBEDDING_DIMS = int(os.environ.get("EMBEDDING_DIMENSIONS", "1024"))

SRC_KNOWLEDGE_INDEX = os.environ.get("SRC_KNOWLEDGE_INDEX", "knowledge")
SRC_MEMORY_INDEX = os.environ.get("SRC_MEMORY_INDEX", "memory-user")
DST_KNOWLEDGE_INDEX = os.environ.get("KNOWLEDGE_INDEX", "memory-knowledge")
DST_FACT_INDEX = os.environ.get("FACT_INDEX", "memory-fact")

EMBED_BATCH = 128        # Voyage input cap per request (contract: <=128)
SCROLL_SIZE = 500
SCROLL_TTL = "2m"

_TIMEOUT = httpx.Timeout(connect=5, read=60, write=60, pool=5)
_es = httpx.Client(base_url=ES_URL, auth=(ES_USER, ES_PASSWORD), verify=ES_VERIFY, timeout=_TIMEOUT)
_voyage = httpx.Client(
    base_url=VOYAGE_ENDPOINT,
    headers={"Authorization": f"Bearer {VOYAGE_API_KEY}"},
    timeout=_TIMEOUT,
)


# --------------------------------------------------------------------------- #
# Pure helpers
# --------------------------------------------------------------------------- #
def content_hash(text: str) -> str:
    return hashlib.md5(text.encode("utf-8")).hexdigest()


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# --------------------------------------------------------------------------- #
# Voyage (re-embed at 1024 dims)
# --------------------------------------------------------------------------- #
def embed_documents(texts: list[str], batch: int = EMBED_BATCH) -> list[list[float]]:
    """Re-embed a list of texts with Voyage voyage-3-large (input_type=document).

    Batches at <=128 inputs; one retry on 5xx/timeout per batch. Returns one
    1024-dim vector per input, in the original order.
    """
    out: list[list[float]] = []
    for i in range(0, len(texts), batch):
        chunk = texts[i:i + batch]
        body = {
            "model": EMBEDDING_MODEL,
            "input": chunk,
            "input_type": "document",
            "output_dimension": EMBEDDING_DIMS,
        }
        resp = None
        for attempt in range(2):
            try:
                resp = _voyage.post("/embeddings", json=body)
                if resp.status_code >= 500:
                    raise httpx.HTTPStatusError("5xx", request=resp.request, response=resp)
                break
            except (httpx.HTTPStatusError, httpx.TimeoutException):
                if attempt == 1:
                    raise
                time.sleep(1.0)
        resp.raise_for_status()
        data = sorted(resp.json()["data"], key=lambda d: d["index"])
        out.extend(item["embedding"] for item in data)
    return out


# --------------------------------------------------------------------------- #
# ES scroll + bulk
# --------------------------------------------------------------------------- #
def scroll_all(index: str) -> list[dict]:
    """Scroll every doc out of ``index``. Returns [] if the index is absent."""
    resp = _es.post(f"/{index}/_search", params={"scroll": SCROLL_TTL},
                    json={"size": SCROLL_SIZE, "query": {"match_all": {}}})
    if resp.status_code == 404:
        print(f"[{index}] source index not found — nothing to migrate")
        return []
    resp.raise_for_status()
    payload = resp.json()
    scroll_id = payload.get("_scroll_id")
    hits = payload["hits"]["hits"]
    docs: list[dict] = []
    while hits:
        docs.extend(hits)
        resp = _es.post("/_search/scroll",
                        json={"scroll": SCROLL_TTL, "scroll_id": scroll_id})
        resp.raise_for_status()
        payload = resp.json()
        scroll_id = payload.get("_scroll_id")
        hits = payload["hits"]["hits"]
    if scroll_id:
        try:
            _es.request("DELETE", "/_search/scroll", json={"scroll_id": [scroll_id]})
        except httpx.HTTPError:
            pass  # cleanup best-effort; scroll context TTL-expires anyway
    return docs


def bulk_index(dest: str, pairs: list[tuple[str, dict]]) -> int:
    """Bulk-index (src_id, doc) pairs, preserving _id for re-runnable upserts."""
    lines: list[str] = []
    for src_id, doc in pairs:
        lines.append(json.dumps({"index": {"_index": dest, "_id": src_id}}))
        lines.append(json.dumps(doc, ensure_ascii=False))
    payload = "\n".join(lines) + "\n"
    resp = _es.post("/_bulk", params={"refresh": "false"}, content=payload.encode("utf-8"),
                    headers={"Content-Type": "application/x-ndjson"})
    resp.raise_for_status()
    result = resp.json()
    if result.get("errors"):
        errored = [it for it in result["items"] if it.get("index", {}).get("error")]
        raise RuntimeError(f"bulk index had {len(errored)} errors: {errored[:3]}")
    return len(pairs)


# --------------------------------------------------------------------------- #
# Doc transforms (old field shape -> v2 field shape, per contract §1)
# --------------------------------------------------------------------------- #
def to_knowledge(src: dict, vec: list[float] | None) -> dict:
    """old `knowledge` chunk -> memory-knowledge doc."""
    s = src["_source"]
    text = (s.get("text") or "").strip()
    written = s.get("created_at") or now_iso()
    parent = s.get("source_doc") or src["_id"]
    doc: dict = {
        "content": text,
        "memory_type": "knowledge",
        "dataset": s.get("dataset") or "main_dataset",
        "chunk_index": s.get("chunk_index", 0),
        "parent_id": parent,
        "content_hash": content_hash(text),
        "use_count": 0,
        "last_used_at": written,
        "provenance": {
            "source_class": "migration",
            "written_at": written,
        },
    }
    if vec is not None:
        doc["embedding"] = vec
    return doc


def to_fact(src: dict, vec: list[float] | None) -> dict:
    """old `memory-user` memory -> memory-fact doc."""
    s = src["_source"]
    text = (s.get("memory") or "").strip()
    written = s.get("created_at") or now_iso()
    doc: dict = {
        "content": text,
        "memory_type": "fact",
        "reconcile_status": "reconciled",
        "content_hash": s.get("hash") or content_hash(text),
        "use_count": 0,
        "last_used_at": written,
        "provenance": {
            "source_class": "migration",
            "written_at": written,
        },
    }
    if vec is not None:
        doc["embedding"] = vec
    return doc


# --------------------------------------------------------------------------- #
# Migrate one family
# --------------------------------------------------------------------------- #
def migrate(src_index: str, dest_index: str, transform, text_key: str, apply: bool) -> int:
    hits = scroll_all(src_index)
    print(f"[{src_index}] scrolled {len(hits)} docs")
    usable = [h for h in hits if (h["_source"].get(text_key) or "").strip()]
    skipped = len(hits) - len(usable)
    if skipped:
        print(f"[{src_index}] {skipped} docs skipped (empty '{text_key}')")

    if not apply:
        for h in usable[:2]:
            sample = {"_id": h["_id"], **transform(h, None)}
            print("  sample -> " + json.dumps(sample, ensure_ascii=False)[:400])
        print(f"[{src_index}] DRY-RUN — would re-embed + write {len(usable)} docs "
              f"to '{dest_index}'")
        return 0

    written = 0
    for i in range(0, len(usable), EMBED_BATCH):
        batch = usable[i:i + EMBED_BATCH]
        texts = [(b["_source"].get(text_key) or "").strip() for b in batch]
        vecs = embed_documents(texts)
        pairs = [(b["_id"], transform(b, v)) for b, v in zip(batch, vecs)]
        written += bulk_index(dest_index, pairs)
        print(f"[{src_index}] indexed {written}/{len(usable)} -> '{dest_index}'")
    return written


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--apply", action="store_true",
                    help="re-embed + write to ES (default: dry-run, no writes)")
    ap.add_argument("--only", choices=["knowledge", "fact"],
                    help="migrate only one family")
    args = ap.parse_args()

    if args.apply and not VOYAGE_API_KEY:
        raise SystemExit("VOYAGE_API_KEY is required for --apply (re-embedding).")

    totals: dict[str, int] = {}
    if args.only in (None, "knowledge"):
        totals[DST_KNOWLEDGE_INDEX] = migrate(
            SRC_KNOWLEDGE_INDEX, DST_KNOWLEDGE_INDEX, to_knowledge, "text", args.apply)
    if args.only in (None, "fact"):
        totals[DST_FACT_INDEX] = migrate(
            SRC_MEMORY_INDEX, DST_FACT_INDEX, to_fact, "memory", args.apply)

    mode = "APPLIED" if args.apply else "DRY-RUN"
    print(f"\n== {mode} ==", file=sys.stderr)
    for name, count in totals.items():
        print(f"  {name}: {count} docs", file=sys.stderr)


if __name__ == "__main__":
    main()
