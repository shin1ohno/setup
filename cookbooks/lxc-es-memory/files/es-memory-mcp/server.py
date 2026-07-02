"""es-memory-mcp — unified MCP server backing Cognee + Mem0 tool surfaces with
ElasticSearch.

Two MCP namespaces are mounted so the existing claude.ai connector tool names
are preserved 1:1 (no CLAUDE.md / allowlist rewrite needed):

    /cognee/mcp  → search, cognify, save_interaction, list_data, delete,
                   cognify_status, prune
    /memory/mcp  → add_memories, search_memory, list_memories,
                   delete_all_memories

Run: uvicorn server:app --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

import json

from contextlib import asynccontextmanager

from mcp.server.fastmcp import FastMCP
from starlette.applications import Starlette
from starlette.routing import Mount

import es_backend as be

cognee_mcp = FastMCP("cognee", stateless_http=True)
memory_mcp = FastMCP("ai-memory", stateless_http=True)

# Self-bootstrap the ES indices on startup (idempotent, retries on cold ES).
be.ensure_indices()


# =========================================================================== #
# Cognee-compatible namespace (knowledge index)
# =========================================================================== #
@cognee_mcp.tool()
def cognify(data: str, dataset_name: str = "main_dataset") -> str:
    """Ingest text into the knowledge store: chunk → embed → index, plus an
    LLM summary for SUMMARIES search. `dataset_name` mirrors Cognee datasets."""
    chunks = be.chunk_text(data)
    if not chunks:
        return "No content to ingest."
    summary = ""
    try:
        summary = be.llm(
            f"Summarize the following content in 2-3 sentences:\n\n{data[:6000]}",
            system="You write concise, factual summaries.",
        )
    except Exception:  # summary is best-effort; ingestion must not fail on it
        summary = ""
    vectors = be.embed(chunks)
    now = be._now_iso()
    docs = []
    for i, (chunk, vec) in enumerate(zip(chunks, vectors)):
        docs.append({
            "text": chunk,
            "embedding": vec,
            "dataset": dataset_name,
            "summary": summary,
            "source_doc": be.content_hash(data),
            "chunk_index": i,
            "created_at": now,
            "metadata": {},
        })
    n = be.bulk_index(be.KNOWLEDGE_INDEX, docs)
    return f"Ingested {n} chunk(s) into dataset '{dataset_name}'."


@cognee_mcp.tool()
def save_interaction(content: str, dataset_name: str = "main_dataset") -> str:
    """Light single-document save (no chunking) for troubleshooting notes /
    quick impressions."""
    vec = be.embed_one(content)
    doc = {
        "text": content,
        "embedding": vec,
        "dataset": dataset_name,
        "summary": content[:280],
        "source_doc": be.content_hash(content),
        "chunk_index": 0,
        "created_at": be._now_iso(),
        "metadata": {"kind": "interaction"},
    }
    _id = be.index_doc(be.KNOWLEDGE_INDEX, doc, refresh=True)
    return f"Saved interaction (id={_id}) to dataset '{dataset_name}'."


@cognee_mcp.tool()
def search(search_query: str, search_type: str = "GRAPH_COMPLETION",
           datasets: str | None = None, top_k: int = 10) -> str:
    """Query the knowledge store.

    search_type:
      CHUNKS                       → ranked raw passages (hybrid BM25+kNN)
      SUMMARIES                    → stored summaries
      RAG_COMPLETION/GRAPH_COMPLETION → retrieve top_k then LLM answer
    """
    st = (search_type or "GRAPH_COMPLETION").upper()
    filters = {"dataset": datasets} if datasets else None
    hits = be.hybrid_search(be.KNOWLEDGE_INDEX, search_query, "text",
                            top_k=top_k, filters=filters)

    if st == "CHUNKS":
        return json.dumps(
            [{"text": h["_source"]["text"], "dataset": h["_source"].get("dataset"),
              "score": h["_score"]} for h in hits],
            ensure_ascii=False, indent=2)

    if st == "SUMMARIES":
        seen, out = set(), []
        for h in hits:
            s = h["_source"].get("summary") or ""
            if s and s not in seen:
                seen.add(s)
                out.append({"summary": s, "dataset": h["_source"].get("dataset")})
        return json.dumps(out, ensure_ascii=False, indent=2)

    # RAG_COMPLETION / GRAPH_COMPLETION (graph traversal mapped to RAG)
    if not hits:
        return "No relevant information found."
    context = "\n\n---\n\n".join(h["_source"]["text"] for h in hits)
    answer = be.llm(
        f"Context:\n{context}\n\nQuestion: {search_query}\n\n"
        "Answer using only the context above. If the context is insufficient, "
        "say so.",
        system="You answer questions grounded strictly in the provided context.",
    )
    return answer


@cognee_mcp.tool()
def list_data(dataset_id: str | None = None) -> str:
    """List datasets and their document counts."""
    body = {
        "size": 0,
        "aggs": {"datasets": {"terms": {"field": "dataset", "size": 1000}}},
    }
    if dataset_id:
        body["query"] = {"term": {"dataset": dataset_id}}
    resp = be.es_request("POST", f"/{be.KNOWLEDGE_INDEX}/_search", body)
    resp.raise_for_status()
    buckets = resp.json()["aggregations"]["datasets"]["buckets"]
    lines = ["📂 Datasets (ES `knowledge` index):", "=" * 40]
    for b in buckets:
        lines.append(f"  {b['key']}: {b['doc_count']} docs")
    return "\n".join(lines)


@cognee_mcp.tool()
def delete(data_id: str, dataset_id: str | None = None) -> str:
    """Delete a single document by its ES _id."""
    resp = be.es_request("DELETE", f"/{be.KNOWLEDGE_INDEX}/_doc/{data_id}?refresh=true")
    if resp.status_code == 404:
        return f"Document {data_id} not found."
    resp.raise_for_status()
    return f"Deleted document {data_id}."


@cognee_mcp.tool()
def cognify_status() -> str:
    """Report knowledge-index health and document count."""
    resp = be.es_request("GET", f"/{be.KNOWLEDGE_INDEX}/_count")
    resp.raise_for_status()
    return f"knowledge index: {resp.json()['count']} documents."


@cognee_mcp.tool()
def prune(confirm: bool = False) -> str:
    """Delete ALL documents in the knowledge index. Requires confirm=true."""
    if not confirm:
        return "Refusing to prune without confirm=true."
    be.es_request("POST", f"/{be.KNOWLEDGE_INDEX}/_delete_by_query?refresh=true",
                  {"query": {"match_all": {}}})
    return "Pruned all knowledge documents."


# =========================================================================== #
# Mem0-compatible namespace (memory-user index)
# =========================================================================== #
_EXTRACT_SYS = (
    "You extract durable, atomic facts about the user worth remembering "
    "(attributes, possessions, preferences, plans). Return a JSON array of "
    "short fact strings. If nothing is worth remembering, return []."
)
_RECONCILE_SYS = (
    "You decide how a new fact relates to an existing memory. "
    "Reply with one word: ADD (new, unrelated), UPDATE (supersedes/contradicts "
    "the existing one), or NOOP (already captured)."
)


def _classify_category(fact: str) -> str:
    """A = durable user attribute/preference; B = research fragment. Cheap
    heuristic kept local to avoid an extra LLM round-trip per fact."""
    lowered = fact.lower()
    research_markers = ("api", "version", "released", "cookbook", "dataset",
                        "proposal", "audit", "http", "pr #", "github")
    return "research-frag" if any(m in lowered for m in research_markers) else "user-attr"


@memory_mcp.tool()
def add_memories(text: str) -> str:
    """Extract atomic facts from `text` and reconcile each against existing
    memories (ADD / UPDATE / NOOP) — Mem0's write-side intelligence."""
    try:
        facts = json.loads(be.llm(f"Text:\n{text}", system=_EXTRACT_SYS))
        if not isinstance(facts, list):
            facts = []
    except Exception:
        facts = [text.strip()] if text.strip() else []

    results = []
    for fact in facts:
        fact = str(fact).strip()
        if not fact:
            continue
        existing = be.knn_search(be.MEMORY_INDEX, fact, top_k=3,
                                 filters={"user_id": be.MEM0_USER})
        action = "ADD"
        target_id = None
        if existing:
            top = existing[0]
            decision = be.llm(
                f"Existing memory: {top['_source']['memory']}\nNew fact: {fact}",
                system=_RECONCILE_SYS,
            ).upper()
            if "NOOP" in decision:
                results.append(f"NOOP: {fact}")
                continue
            if "UPDATE" in decision:
                action, target_id = "UPDATE", top["_id"]

        vec = be.embed_one(fact)
        now = be._now_iso()
        doc = {
            "memory": fact, "embedding": vec, "user_id": be.MEM0_USER,
            "category": _classify_category(fact), "hash": be.content_hash(fact),
            "updated_at": now,
        }
        if action == "UPDATE":
            be.es_request("POST", f"/{be.MEMORY_INDEX}/_update/{target_id}?refresh=true",
                          {"doc": doc})
            results.append(f"UPDATE: {fact}")
        else:
            doc["created_at"] = now
            be.index_doc(be.MEMORY_INDEX, doc, refresh=True)
            results.append(f"ADD: {fact}")
    return "\n".join(results) if results else "No new memories extracted."


@memory_mcp.tool()
def search_memory(query: str) -> str:
    """Semantic search over the user's memories."""
    hits = be.knn_search(be.MEMORY_INDEX, query, top_k=10,
                         filters={"user_id": be.MEM0_USER})
    return json.dumps(
        [{"id": h["_id"], "memory": h["_source"]["memory"],
          "category": h["_source"].get("category"), "score": h["_score"]}
         for h in hits],
        ensure_ascii=False, indent=2)


@memory_mcp.tool()
def list_memories() -> str:
    """List all stored memories for the user."""
    body = {"size": 1000, "query": {"term": {"user_id": be.MEM0_USER}}}
    resp = be.es_request("POST", f"/{be.MEMORY_INDEX}/_search", body)
    resp.raise_for_status()
    hits = resp.json()["hits"]["hits"]
    return json.dumps(
        [{"id": h["_id"], "memory": h["_source"]["memory"],
          "category": h["_source"].get("category"),
          "created_at": h["_source"].get("created_at")} for h in hits],
        ensure_ascii=False, indent=2)


@memory_mcp.tool()
def delete_all_memories() -> str:
    """Delete every memory for the user."""
    be.es_request("POST", f"/{be.MEMORY_INDEX}/_delete_by_query?refresh=true",
                  {"query": {"term": {"user_id": be.MEM0_USER}}})
    return "Deleted all memories."


# =========================================================================== #
# Mount both namespaces under one Starlette app
# =========================================================================== #
# Mounted FastMCP sub-apps do NOT get their lifespan run by the parent
# Starlette automatically. Without running each app's StreamableHTTPSessionManager
# via its lifespan, every request 500s ("session manager not initialized").
# Run both session managers from the parent lifespan.
@asynccontextmanager
async def lifespan(_app):
    async with cognee_mcp.session_manager.run():
        async with memory_mcp.session_manager.run():
            yield


app = Starlette(
    routes=[
        Mount("/cognee", app=cognee_mcp.streamable_http_app()),
        Mount("/memory", app=memory_mcp.streamable_http_app()),
    ],
    lifespan=lifespan,
)
