"""ElasticSearch backend for es-memory-mcp.

Replaces Cognee (knowledge graph / RAG) and Mem0 (user memory) storage with a
single 3-node ES cluster (basic license, no ML). Embeddings are computed
externally via OpenAI (text-embedding-3-small, 1536-dim) and stored as
`dense_vector`; search is BM25 + kNN hybrid.

Hybrid strategy: try the RRF retriever first; if the cluster rejects it
(basic-license gating on some 8.x/9.x builds), fall back to running kNN and
BM25 as separate queries and merging with the RRF formula in Python. Both
paths work on a basic license.
"""

from __future__ import annotations

import hashlib
import os
import time
from typing import Any

import httpx

ES_URL = os.environ["ES_URL"].rstrip("/")
ES_USER = os.environ.get("ES_USER", "elastic")
ES_PASSWORD = os.environ["ES_PASSWORD"]
ES_VERIFY = os.environ.get("ES_VERIFY_CERTS", "false").lower() == "true"

OPENAI_API_KEY = os.environ["OPENAI_API_KEY"]
OPENAI_BASE = os.environ.get("OPENAI_ENDPOINT", "https://api.openai.com/v1").rstrip("/")
EMBEDDING_MODEL = os.environ.get("EMBEDDING_MODEL", "text-embedding-3-small")
EMBEDDING_DIMS = int(os.environ.get("EMBEDDING_DIMENSIONS", "1536"))
LLM_MODEL = os.environ.get("LLM_MODEL", "gpt-5-mini")

KNOWLEDGE_INDEX = os.environ.get("KNOWLEDGE_INDEX", "knowledge")
MEMORY_INDEX = os.environ.get("MEMORY_INDEX", "memory-user")
MEM0_USER = os.environ.get("MEM0_USER", "shin1ohno")

RRF_K = 60

# Module-level cache: whether the cluster supports the RRF retriever. None = not
# yet probed; True/False set after the first hybrid search attempt.
_rrf_supported: bool | None = None

_es = httpx.Client(
    base_url=ES_URL,
    auth=(ES_USER, ES_PASSWORD),
    verify=ES_VERIFY,
    timeout=30.0,
)
_openai = httpx.Client(
    base_url=OPENAI_BASE,
    headers={"Authorization": f"Bearer {OPENAI_API_KEY}"},
    timeout=60.0,
)


# --------------------------------------------------------------------------- #
# OpenAI helpers
# --------------------------------------------------------------------------- #
def embed(texts: list[str]) -> list[list[float]]:
    """Embed a batch of texts. Returns one 1536-dim vector per input."""
    if not texts:
        return []
    resp = _openai.post(
        "/embeddings",
        json={"model": EMBEDDING_MODEL, "input": texts},
    )
    resp.raise_for_status()
    data = resp.json()["data"]
    return [item["embedding"] for item in sorted(data, key=lambda d: d["index"])]


def embed_one(text: str) -> list[float]:
    return embed([text])[0]


def llm(prompt: str, system: str | None = None) -> str:
    """Single-shot chat completion used for fact extraction, reconciliation,
    summaries, and RAG completion."""
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})
    resp = _openai.post(
        "/chat/completions",
        json={"model": LLM_MODEL, "messages": messages},
    )
    resp.raise_for_status()
    return resp.json()["choices"][0]["message"]["content"].strip()


# --------------------------------------------------------------------------- #
# ES low-level
# --------------------------------------------------------------------------- #
def es_request(method: str, path: str, body: dict | None = None) -> httpx.Response:
    return _es.request(method, path, json=body)


# Index definitions kept in-process so the server is self-bootstrapping (no
# separate setup script / .env-sourcing step in the cookbook). Mirrors
# files/es-indices/*.json — keep the two in sync.
_INDEX_DEFS: dict[str, dict] = {
    KNOWLEDGE_INDEX: {
        "settings": {"number_of_shards": 1, "number_of_replicas": 1},
        "mappings": {"properties": {
            "text": {"type": "text"},
            "embedding": {"type": "dense_vector", "dims": EMBEDDING_DIMS,
                          "index": True, "similarity": "cosine"},
            "dataset": {"type": "keyword"},
            "summary": {"type": "text"},
            "source_doc": {"type": "keyword"},
            "chunk_index": {"type": "integer"},
            "created_at": {"type": "date"},
            "metadata": {"type": "object", "enabled": True},
        }},
    },
    MEMORY_INDEX: {
        "settings": {"number_of_shards": 1, "number_of_replicas": 1},
        "mappings": {"properties": {
            "memory": {"type": "text"},
            "embedding": {"type": "dense_vector", "dims": EMBEDDING_DIMS,
                          "index": True, "similarity": "cosine"},
            "user_id": {"type": "keyword"},
            "category": {"type": "keyword"},
            "hash": {"type": "keyword"},
            "created_at": {"type": "date"},
            "updated_at": {"type": "date"},
        }},
    },
}


def ensure_indices(retries: int = 10, delay: float = 3.0) -> None:
    """Idempotently create the knowledge + memory-user indices on startup.
    Retries because ES may not be reachable the instant the container boots."""
    last_err: Exception | None = None
    for attempt in range(retries):
        try:
            for name, body in _INDEX_DEFS.items():
                resp = es_request("PUT", f"/{name}", body)
                if resp.status_code in (200, 201):
                    continue
                if resp.status_code == 400 and \
                        "resource_already_exists_exception" in resp.text:
                    continue
                resp.raise_for_status()
            return
        except Exception as exc:  # noqa: BLE001 — startup retry loop
            last_err = exc
            time.sleep(delay)
    if last_err:
        raise last_err


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def index_doc(index: str, doc: dict, doc_id: str | None = None, refresh: bool = False) -> str:
    suffix = "?refresh=true" if refresh else ""
    if doc_id:
        resp = es_request("PUT", f"/{index}/_doc/{doc_id}{suffix}", doc)
    else:
        resp = es_request("POST", f"/{index}/_doc{suffix}", doc)
    resp.raise_for_status()
    return resp.json()["_id"]


def bulk_index(index: str, docs: list[dict]) -> int:
    """Bulk-index documents. Each doc may carry an optional `_id`."""
    lines: list[str] = []
    import json as _json

    for d in docs:
        meta: dict[str, Any] = {"index": {"_index": index}}
        if "_id" in d:
            meta["index"]["_id"] = d.pop("_id")
        lines.append(_json.dumps(meta))
        lines.append(_json.dumps(d))
    payload = "\n".join(lines) + "\n"
    resp = _es.post("/_bulk?refresh=true", content=payload,
                    headers={"Content-Type": "application/x-ndjson"})
    resp.raise_for_status()
    result = resp.json()
    if result.get("errors"):
        errored = [item for item in result["items"] if item["index"].get("error")]
        raise RuntimeError(f"bulk index had {len(errored)} errors: {errored[:3]}")
    return len(docs)


# --------------------------------------------------------------------------- #
# Hybrid search (RRF retriever with manual fallback)
# --------------------------------------------------------------------------- #
def _filter_clause(filters: dict[str, Any] | None) -> list[dict]:
    if not filters:
        return []
    return [{"term": {k: v}} for k, v in filters.items()]


def hybrid_search(
    index: str,
    query: str,
    text_field: str,
    top_k: int = 10,
    filters: dict[str, Any] | None = None,
) -> list[dict]:
    """BM25 + kNN hybrid. Returns a list of {_id, _score, _source} hits."""
    global _rrf_supported
    qvec = embed_one(query)
    flt = _filter_clause(filters)

    if _rrf_supported is not False:
        hits = _rrf_search(index, query, text_field, qvec, top_k, flt)
        if hits is not None:
            _rrf_supported = True
            return hits
        _rrf_supported = False  # cache the gating so we skip RRF next time

    return _manual_hybrid(index, query, text_field, qvec, top_k, flt)


def _rrf_search(index, query, text_field, qvec, top_k, flt) -> list[dict] | None:
    """Returns hits, or None if RRF is unsupported (license/parse error)."""
    body = {
        "size": top_k,
        "retriever": {
            "rrf": {
                "retrievers": [
                    {"standard": {"query": {
                        "bool": {"must": {"match": {text_field: query}}, "filter": flt}}}},
                    {"knn": {
                        "field": "embedding", "query_vector": qvec,
                        "k": top_k, "num_candidates": max(top_k * 5, 50),
                        "filter": flt}},
                ],
                "rank_window_size": max(top_k * 5, 50),
                "rank_constant": RRF_K,
            }
        },
    }
    resp = es_request("POST", f"/{index}/_search", body)
    if resp.status_code == 400 or resp.status_code == 403:
        # license-gated retriever or unsupported syntax → signal fallback
        return None
    resp.raise_for_status()
    return resp.json()["hits"]["hits"]


def _manual_hybrid(index, query, text_field, qvec, top_k, flt) -> list[dict]:
    """Run BM25 and kNN separately, merge with the RRF formula in Python."""
    cand = max(top_k * 5, 50)
    bm25_body = {
        "size": cand,
        "query": {"bool": {"must": {"match": {text_field: query}}, "filter": flt}},
    }
    knn_body = {
        "size": cand,
        "knn": {"field": "embedding", "query_vector": qvec,
                "k": cand, "num_candidates": cand * 2, "filter": flt},
    }
    bm25_hits = es_request("POST", f"/{index}/_search", bm25_body).json()["hits"]["hits"]
    knn_hits = es_request("POST", f"/{index}/_search", knn_body).json()["hits"]["hits"]

    scores: dict[str, float] = {}
    sources: dict[str, dict] = {}
    for ranked in (bm25_hits, knn_hits):
        for rank, hit in enumerate(ranked):
            _id = hit["_id"]
            scores[_id] = scores.get(_id, 0.0) + 1.0 / (RRF_K + rank + 1)
            sources[_id] = hit
    ordered = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)[:top_k]
    return [{"_id": _id, "_score": score, "_source": sources[_id]["_source"]}
            for _id, score in ordered]


def knn_search(index, query, top_k=10, filters=None) -> list[dict]:
    """Pure kNN (used for memory recall where BM25 adds little)."""
    qvec = embed_one(query)
    body = {
        "size": top_k,
        "knn": {"field": "embedding", "query_vector": qvec,
                "k": top_k, "num_candidates": max(top_k * 5, 50),
                "filter": _filter_clause(filters)},
    }
    resp = es_request("POST", f"/{index}/_search", body)
    resp.raise_for_status()
    return resp.json()["hits"]["hits"]


# --------------------------------------------------------------------------- #
# Chunking
# --------------------------------------------------------------------------- #
def chunk_text(text: str, size: int = 1200, overlap: int = 150) -> list[str]:
    """Character-window chunking with overlap. Splits on paragraph boundaries
    when possible to keep chunks coherent."""
    text = text.strip()
    if len(text) <= size:
        return [text] if text else []
    chunks: list[str] = []
    start = 0
    while start < len(text):
        end = min(start + size, len(text))
        # prefer to break at a paragraph/sentence boundary near the window end
        if end < len(text):
            window = text[start:end]
            for sep in ("\n\n", "\n", ". ", " "):
                idx = window.rfind(sep)
                if idx > size * 0.5:
                    end = start + idx + len(sep)
                    break
        chunks.append(text[start:end].strip())
        start = max(end - overlap, start + 1)
    return [c for c in chunks if c]


def content_hash(text: str) -> str:
    return hashlib.md5(text.encode("utf-8")).hexdigest()
