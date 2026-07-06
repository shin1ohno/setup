"""es-memory-mcp — Mem0-compatible MCP server backed by ElasticSearch.

The /memory namespace is mounted so the existing claude.ai connector tool
names are preserved 1:1:

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

# Stateful (session-based) streamable HTTP — NOT stateless_http=True. The
# claude.ai MCP connector requires the server to issue an `Mcp-Session-Id`
# header on initialize and to hold session state for follow-up requests;
# stateless mode omits the session id, so the connector's handshake fails
# after OAuth with "no MCP server found at the provided URL". Single-worker
# uvicorn (see the unit's --workers 1) keeps session state consistent.
memory_mcp = FastMCP("ai-memory")

# Self-bootstrap the ES indices on startup (idempotent, retries on cold ES).
be.ensure_indices()


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
# Mount the memory namespace under a Starlette app
# =========================================================================== #
# The mounted FastMCP sub-app does NOT get its lifespan run by the parent
# Starlette automatically. Without running the app's StreamableHTTPSessionManager
# via its lifespan, every request 500s ("session manager not initialized").
# Run the session manager from the parent lifespan.
@asynccontextmanager
async def lifespan(_app):
    async with memory_mcp.session_manager.run():
        yield


app = Starlette(
    routes=[
        Mount("/memory", app=memory_mcp.streamable_http_app()),
    ],
    lifespan=lifespan,
)
