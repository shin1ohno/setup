"""Session search server API (design spec §6.5 C6, §7.2 routes, §7.6 gate).

Mounted by server.py as `Mount("/memory/sessions/v1", sessions_app.app)` AHEAD
of `Mount("/memory", mcp)`, so /memory/mcp is not shadowed.

Gate (decision I). One ASGI wrapper sits in front of every route and runs, in
order:

  1. the proxy shared secret must be configured on this server (otherwise any
     local process could forge the identity headers) and present on the request
     (identity.require_proxy_secret) — 403 / 401;
  2. identity.parse_identity — the X-Verified-* headers the proxy injected;
  3. the fixed ROUTES table: an unlisted (method, path) is 403, whatever its
     shape (`..`, `%2F`, trailing slash and HEAD are all unlisted);
  4. identity.authorize_session_scope against SESSION_SCOPE_POLICY, which also
     yields the caller's host. Unset or malformed policy = deny-all.

The host of a write is NEVER taken from the request body: it comes from step 4,
and a write whose target session belongs to another host is 403 host_mismatch.

Ingest pipeline (§6.5): bounded body read → bounded gzip → C2 re-scan in
detect-only mode with the client's declared ruleset (422 names line indexes and
kinds, never values) → C1 parse → archive chunk (main only) → `_bulk` WITHOUT
refresh → session doc → embedding queued in the background.

`es` handed to sessions_search.search / preview is the es_backend module itself
(its `_es_json`, `_es` client and index constants). `caller` is the dict
{sub, client_id, grant, agent, host, scope}.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import importlib
import importlib.util
import inspect
import io
import json
import os
import re
import sys
import tarfile
import time
import zlib

from starlette.requests import Request
from starlette.responses import JSONResponse, Response

import es_backend as be  # attributes are read at call time only (tests stub the module)
import identity
import session_redact
import sessions_archive
import sessions_parse

# sessions_search.py belongs to a separate stream. Missing module = the two
# routes answer 501; a module that exists but fails to import is a real bug and
# propagates.
if importlib.util.find_spec("sessions_search") is not None:
    sessions_search = importlib.import_module("sessions_search")
else:
    sessions_search = None

SCHEMA_SESSION = "session/1"
SCHEMA_MESSAGE = "session-message/1"
SESSION_INDEX = os.environ.get("SESSION_INDEX", "memory-session")
MESSAGE_INDEX = os.environ.get("SESSION_MESSAGE_INDEX", "memory-session-message")
# 1 on personal (3-node cluster), 0 on work (single node) — §7.1.
SESSION_INDEX_REPLICAS = int(os.environ.get("SESSION_INDEX_REPLICAS", "1"))

WIRE_MAX = 8 * 1024 * 1024          # bytes on the wire (§7.2)
DECOMPRESSED_MAX = 5 * 1024 * 1024  # bytes after gunzip (§6.5 step 2)
EMBED_TEXT_CAP = 16 * 1024
EMBED_BATCH = 128

SESSION_ID_RE = sessions_archive.SESSION_ID_RE
SESSION_KEY_RE = sessions_archive.SESSION_KEY_RE
HOST_RE = sessions_archive.HOST_RE
TOOL_RESULT_NAME_RE = sessions_archive.TOOL_RESULT_NAME_RE
PROJECT_DIR_RE = re.compile(r"^[A-Za-z0-9-]{1,255}$")
AGENT_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

SCOPE_INGEST = "sessions:ingest"
SCOPE_READ = "sessions:read"
SCOPE_PURGE = "sessions:purge"

# The fixed route -> scope table. Anything not here is 403.
ROUTES = {
    ("POST", "/ingest"): SCOPE_INGEST,
    ("POST", "/blob"): SCOPE_INGEST,
    ("POST", "/state"): SCOPE_INGEST,
    ("POST", "/search"): SCOPE_READ,
    ("GET", "/preview"): SCOPE_READ,
    ("GET", "/archive"): SCOPE_READ,
    ("GET", "/archive/tool-results"): SCOPE_READ,
    ("DELETE", "/session"): SCOPE_PURGE,
    ("GET", "/status"): SCOPE_READ,
}

# Readiness: the session indices must exist with the expected _meta.schema.
# Until then every route except /status answers 503, and the MCP server under
# /memory keeps serving (a missing grant on the work ES must not take recall
# down with it).
_STATE = {"ready": False, "error": "starting", "started": False}
# In-process counters surfaced by /status (§8 row 4).
_COUNTERS = {"unknown_types": {}, "rejected_lines": 0, "ingested_segments": 0}
_BG_TASKS: set = set()


def _log(msg: str) -> None:
    print(f"SESSIONS {msg}", file=sys.stderr, flush=True)


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _err(status: int, code: str, **extra) -> JSONResponse:
    return JSONResponse({"error": code, **extra}, status_code=status)


class HTTPError(Exception):
    def __init__(self, status: int, code: str, **extra):
        super().__init__(code)
        self.status = status
        self.code = code
        self.extra = extra


def make_session_key(host: str, project_dir: str, session_id: str) -> str:
    """Opaque, server-issued (§6.5): sk_ + base32(sha256(host\\0dir\\0sid)[:20])."""
    raw = hashlib.sha256(f"{host}\0{project_dir}\0{session_id}".encode("utf-8")).digest()[:20]
    return "sk_" + base64.b32encode(raw).decode("ascii").lower()


# --------------------------------------------------------------------------- #
# Index definitions (§7.1). Mirrors files/es-indices-v2/memory-session*.json;
# test_sessions_app.py asserts they stay identical.
# --------------------------------------------------------------------------- #
def index_definitions(analysis=None, replicas: int | None = None) -> dict:
    analysis = be._ANALYSIS if analysis is None else analysis
    kw = {"type": "keyword"}
    session = {
        "settings": {"number_of_shards": 1, "codec": "best_compression", "analysis": analysis},
        "mappings": {
            "dynamic": "strict",
            "_meta": {"schema": SCHEMA_SESSION},
            "properties": {
                "session_key": kw, "session_id": kw, "host": kw, "project_dir": kw,
                "jsonl_path": {"type": "keyword", "index": False},
                "cwd": kw, "cwd_candidates": kw, "resume_cwd": kw,
                "resume_cwd_verified": {"type": "boolean"},
                "title": {"type": "text", "analyzer": "ja_en_hybrid",
                          "fields": {"raw": {"type": "keyword", "ignore_above": 256}}},
                "title_source": kw, "git_branch": kw, "entrypoint": kw,
                "interactive": {"type": "boolean"}, "cc_version": kw,
                "started_at": {"type": "date"}, "updated_at": {"type": "date"},
                "message_count": {"type": "integer"}, "text_message_count": {"type": "integer"},
                "has_subagents": {"type": "boolean"}, "jsonl_exists": {"type": "boolean"},
                "jsonl_checked_at": {"type": "date"}, "archived": {"type": "boolean"},
                "archive_complete": {"type": "boolean"},
                "archive_generation": {"type": "integer"}, "archive_bytes": {"type": "long"},
                "archive_chunks": {"type": "object", "enabled": False},
                "restored_from": kw, "redact_version": kw, "parser_version": kw,
            },
        },
    }
    message = {
        "settings": {"number_of_shards": 1, "codec": "best_compression",
                     "refresh_interval": "1s", "analysis": analysis},
        "mappings": {
            "dynamic": "strict",
            "_meta": {"schema": SCHEMA_MESSAGE},
            "_source": {"excludes": ["embedding"]},
            "properties": {
                "session_key": kw, "session_id": kw, "host": kw, "cwd": kw,
                "interactive": {"type": "boolean"}, "uuid": kw, "parent_uuid": kw,
                "message_id": kw, "role": kw, "ts": {"type": "date"},
                "is_sidechain": {"type": "boolean"}, "agent_id": kw,
                "text": {"type": "text", "analyzer": "ja_en_hybrid"},
                "tool_text": {"type": "text", "analyzer": "ja_en_hybrid"},
                "tool_names": kw,
                "embedding": {"type": "dense_vector", "dims": 1024, "similarity": "cosine",
                              "index_options": {"type": "int8_hnsw"}},
                "embedding_status": kw, "line_offset": {"type": "long"}, "redact_version": kw,
            },
        },
    }
    if replicas is not None:
        session["settings"]["number_of_replicas"] = replicas
        message["settings"]["number_of_replicas"] = replicas
    return {SESSION_INDEX: (session, SCHEMA_SESSION), MESSAGE_INDEX: (message, SCHEMA_MESSAGE)}


class SchemaMismatch(Exception):
    pass


async def ensure_session_indices() -> None:
    """Create both indices when missing (403-tolerant like es_backend.
    ensure_indices) and check `_meta.schema` (§8 row 11). Raises on failure."""
    async with be._make_client() as client:
        for name, (body, schema) in index_definitions(replicas=SESSION_INDEX_REPLICAS).items():
            resp = await client.request("PUT", f"/{name}", json=body)
            ok = resp.status_code in (200, 201) or (
                resp.status_code == 400 and "resource_already_exists_exception" in resp.text) or (
                resp.status_code == 403 and await be._index_exists(client, name))
            if not ok:
                raise RuntimeError(f"create {name}: HTTP {resp.status_code}")
            m = await client.request("GET", f"/{name}/_mapping")
            if m.status_code != 200:
                raise RuntimeError(f"mapping {name}: HTTP {m.status_code}")
            got = None
            for v in (m.json() or {}).values():
                got = ((v.get("mappings") or {}).get("_meta") or {}).get("schema")
                break
            if got != schema:
                raise SchemaMismatch(f"{name}: _meta.schema={got!r}, expected {schema!r}")


async def _startup_loop(delay: float = 30.0) -> None:
    attempt = 0
    while True:
        attempt += 1
        try:
            await ensure_session_indices()
            _STATE.update(ready=True, error="")
            _log("indices ready")
            return
        except Exception as exc:  # noqa: BLE001 — retried forever, logged every time
            _STATE.update(ready=False, error=f"{exc.__class__.__name__}: {exc}"[:300])
            _log(f"indices not ready attempt={attempt} error={_STATE['error']}")
        await asyncio.sleep(min(delay * attempt, 300.0))


def start_background() -> None:
    """Called from server.py's lifespan. Never blocks startup."""
    if _STATE["started"]:
        return
    _STATE["started"] = True
    for line in identity.session_scope_policy_lines():
        print(line, file=sys.stderr, flush=True)
    if not identity.proxy_secret_configured():
        _log("gate refuses every request: PROXY_SHARED_SECRET is not set")
    _spawn(_startup_loop())


def _spawn(coro):
    task = asyncio.get_running_loop().create_task(coro)
    _BG_TASKS.add(task)
    task.add_done_callback(_BG_TASKS.discard)
    return task


# --------------------------------------------------------------------------- #
# ES helpers (status-aware; es_backend._es_json raises on every 4xx)
# --------------------------------------------------------------------------- #
class ESUnavailable(Exception):
    pass


async def _es(method: str, path: str, **kw):
    try:
        return await be._es.request(method, path, **kw)
    except Exception as exc:  # noqa: BLE001 — transport errors become 503
        raise ESUnavailable(exc.__class__.__name__) from exc


async def _get_session(session_key: str):
    """(source, seq_no, primary_term) or None."""
    r = await _es("GET", f"/{SESSION_INDEX}/_doc/{session_key}")
    if r.status_code == 404:
        return None
    if r.status_code != 200:
        raise ESUnavailable(f"get session: {r.status_code}")
    data = r.json()
    if not data.get("found"):
        return None
    return data["_source"], data.get("_seq_no"), data.get("_primary_term")


async def _put_session(session_key: str, doc: dict, seq=None, term=None) -> None:
    path = f"/{SESSION_INDEX}/_doc/{session_key}"
    if seq is not None and term is not None:
        path += f"?if_seq_no={seq}&if_primary_term={term}"
    r = await _es("PUT", path, json=doc)
    if r.status_code == 409:
        raise HTTPError(503, "busy")
    if r.status_code >= 400:
        raise ESUnavailable(f"put session: {r.status_code}")


async def _update_session(session_key: str, partial: dict, upsert: dict | None = None) -> int:
    body = {"doc": partial}
    if upsert is not None:
        body["upsert"] = upsert
    r = await _es("POST", f"/{SESSION_INDEX}/_update/{session_key}?retry_on_conflict=3", json=body)
    if r.status_code >= 400 and r.status_code != 404:
        raise ESUnavailable(f"update session: {r.status_code}")
    return r.status_code


async def _bulk_index(index: str, docs: list[dict]) -> int:
    """`_bulk` WITHOUT refresh (§6.5 step 5): the 1 s refresh interval is fast
    enough for a picker. es_backend._bulk_index forces refresh=true, so it is
    not reused here. Docs keep their `_id` key; it becomes the action id."""
    if not docs:
        return 0
    lines = []
    for d in docs:
        lines.append(json.dumps({"index": {"_index": index, "_id": d["_id"]}}))
        lines.append(json.dumps({k: v for k, v in d.items() if k != "_id"}))
    r = await _es("POST", "/_bulk", content="\n".join(lines) + "\n",
                  headers={"Content-Type": "application/x-ndjson"})
    if r.status_code >= 400:
        raise ESUnavailable(f"bulk: {r.status_code}")
    res = r.json()
    if res.get("errors"):
        bad = [i for i in res.get("items", []) if (i.get("index") or {}).get("error")]
        types = sorted({(i["index"]["error"] or {}).get("type", "?") for i in bad})
        _log(f"bulk errors index={index} count={len(bad)} types={','.join(types)}")
        raise ESUnavailable("bulk had errors")
    return len(docs)


async def _delete_messages(session_key: str) -> int:
    r = await _es("POST", f"/{MESSAGE_INDEX}/_delete_by_query?conflicts=proceed",
                  json={"query": {"term": {"session_key": session_key}}})
    if r.status_code >= 400:
        raise ESUnavailable(f"delete_by_query: {r.status_code}")
    return int(r.json().get("deleted", 0))


async def _count(index: str, query: dict | None = None) -> int | None:
    r = await _es("POST", f"/{index}/_count", json={"query": query or {"match_all": {}}})
    if r.status_code != 200:
        return None
    return int(r.json().get("count", 0))


# --------------------------------------------------------------------------- #
# Body handling (bounded)
# --------------------------------------------------------------------------- #
async def _read_body(request: Request) -> bytes:
    cl = request.headers.get("content-length")
    if cl is not None:
        try:
            if int(cl) > WIRE_MAX:
                raise HTTPError(413, "too_large")
        except ValueError:
            raise HTTPError(400, "bad_content_length") from None
    buf = bytearray()
    async for chunk in request.stream():
        buf += chunk
        if len(buf) > WIRE_MAX:
            raise HTTPError(413, "too_large")
    return bytes(buf)


def _gunzip_bounded(data: bytes, limit: int = DECOMPRESSED_MAX) -> bytes:
    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    try:
        out = d.decompress(data, limit + 1)
    except zlib.error:
        raise HTTPError(400, "bad_gzip") from None
    if len(out) > limit or d.unconsumed_tail:
        raise HTTPError(413, "too_large")
    if not d.eof:
        raise HTTPError(400, "bad_gzip")
    return out


async def _json_body(request: Request) -> dict:
    raw = await _read_body(request)
    if raw[:2] == b"\x1f\x8b":
        raw = _gunzip_bounded(raw)
    elif len(raw) > DECOMPRESSED_MAX:
        raise HTTPError(413, "too_large")
    try:
        body = json.loads(raw)
    except ValueError:
        raise HTTPError(400, "bad_json") from None
    if not isinstance(body, dict):
        raise HTTPError(400, "bad_json")
    return body


def _int(v, name, minimum=0):
    if not isinstance(v, int) or isinstance(v, bool) or v < minimum:
        raise HTTPError(400, "invalid_request", field=name)
    return v


def _str(v, name, regex=None, maxlen=4096):
    if not isinstance(v, str) or not v or len(v) > maxlen or (regex and not regex.fullmatch(v)):
        raise HTTPError(400, "invalid_request", field=name)
    return v


def _session_key_param(v) -> str:
    if not isinstance(v, str) or not SESSION_KEY_RE.fullmatch(v):
        raise HTTPError(400, "invalid_session_key")
    return v


def _require_host(caller) -> str:
    if not caller.get("host"):
        raise HTTPError(403, "host_mismatch")
    return caller["host"]


async def _owned_session(session_key: str, caller, *, allow_hostless=False):
    got = await _get_session(session_key)
    if got is None:
        raise HTTPError(404, "not_found")
    src = got[0]
    if caller.get("host") is None and allow_hostless:
        return got
    if src.get("host") != _require_host(caller):
        raise HTTPError(403, "host_mismatch")
    return got


def _segment_chunks(chunks):
    return [c for c in chunks or [] if "name" not in c]


def _blob_entries(chunks):
    return [c for c in chunks or [] if "name" in c]


# --------------------------------------------------------------------------- #
# Embedding queue (§6.5 "Embedding")
# --------------------------------------------------------------------------- #
_EMBED_LOCK = None


async def _embed_docs(docs: list[dict]) -> None:
    """Embed text docs in batches of 128 and re-index them with the vector.
    The whole doc is re-indexed rather than _update'd: `embedding` is excluded
    from _source, so any partial update would rebuild the doc without it.
    A failed batch keeps embedding_status=pending for C8 to retry."""
    global _EMBED_LOCK
    if _EMBED_LOCK is None:
        _EMBED_LOCK = asyncio.Lock()
    async with _EMBED_LOCK:
        try:
            import voyage  # noqa: PLC0415 — lazy: reads VOYAGE_API_KEY at import
        except Exception as exc:  # noqa: BLE001
            _log(f"embedding unavailable: {exc.__class__.__name__}")
            return
        for i in range(0, len(docs), EMBED_BATCH):
            batch = docs[i:i + EMBED_BATCH]
            texts = [sessions_parse._cap_bytes(d["text"], EMBED_TEXT_CAP) for d in batch]
            try:
                vecs = await voyage.embed_documents(texts)
                out = []
                for d, v in zip(batch, vecs):
                    nd = dict(d)
                    nd["embedding"] = v
                    nd["embedding_status"] = "done"
                    out.append(nd)
                await _bulk_index(MESSAGE_INDEX, out)
            except Exception as exc:  # noqa: BLE001 — stays pending
                _log(f"embedding batch failed size={len(batch)} error={exc.__class__.__name__}")


def _schedule_embedding(docs: list[dict]) -> None:
    """Indirection so the tests can capture the queued docs."""
    if docs:
        _spawn(_embed_docs(docs))


EMBED_SCHEDULER = _schedule_embedding


def _archive_backend():
    """The configured archive backend (None = archive disabled). Read lazily
    so a bad configuration shows on the request, not at import."""
    if "backend" not in _ARCHIVE:
        try:
            _ARCHIVE["backend"] = sessions_archive.backend_from_env()
        except ValueError as exc:
            _log(f"archive misconfigured: {exc}")
            _ARCHIVE["backend"] = _MISCONFIGURED
    b = _ARCHIVE["backend"]
    if b is _MISCONFIGURED:
        raise HTTPError(503, "archive_unavailable")
    return b


_ARCHIVE: dict = {}
_MISCONFIGURED = object()


# --------------------------------------------------------------------------- #
# Routes
# --------------------------------------------------------------------------- #
async def ingest(request: Request, caller: dict):
    body = await _json_body(request)
    client = body.get("client") if isinstance(body.get("client"), dict) else None
    f = body.get("file") if isinstance(body.get("file"), dict) else None
    seg = body.get("segment") if isinstance(body.get("segment"), dict) else None
    if client is None or f is None or seg is None:
        raise HTTPError(400, "invalid_request", field="client/file/segment")
    host = _require_host(caller)
    # Step 1: the body's host must be the authenticated one.
    if client.get("host") != host:
        raise HTTPError(403, "host_mismatch")
    version = client.get("redact_version")
    if version not in session_redact.SUPPORTED_VERSIONS:
        raise HTTPError(400, "unsupported_redact_version")
    session_id = _str(f.get("session_id"), "file.session_id", SESSION_ID_RE)
    project_dir = _str(f.get("project_dir"), "file.project_dir", PROJECT_DIR_RE)
    jsonl_path = _str(f.get("jsonl_path"), "file.jsonl_path")
    kind = f.get("kind")
    if kind not in ("main", "subagent"):
        raise HTTPError(400, "invalid_request", field="file.kind")
    agent_id = parent_sid = None
    key_sid = session_id
    if kind == "subagent":
        agent_id = _str(f.get("agent_id"), "file.agent_id", AGENT_ID_RE)
        parent_sid = _str(f.get("parent_session_id"), "file.parent_session_id", SESSION_ID_RE)
        # A subagent transcript is its own session doc; its key must never
        # collide with the parent's, whichever id the client sends as session_id.
        key_sid = f"{session_id}\0agent:{agent_id}"
    generation = _int(seg.get("generation"), "segment.generation")
    offset = _int(seg.get("offset"), "segment.offset")
    end_offset = _int(seg.get("end_offset"), "segment.end_offset", offset + 1)
    seg_sha = _str(seg.get("sha256"), "segment.sha256", SHA256_RE)
    lines = seg.get("lines")
    if not isinstance(lines, list) or not lines or not all(isinstance(x, str) for x in lines):
        raise HTTPError(400, "invalid_request", field="segment.lines")

    # Step 3: re-scan every line, detect-only, with the declared ruleset.
    bad_lines, kinds, invalid = [], set(), []
    for i, line in enumerate(lines):
        try:
            rec = json.loads(line)
        except ValueError:
            invalid.append(i)
            continue
        if not isinstance(rec, (dict, list)):
            invalid.append(i)
            continue
        hit = session_redact.detect_record(rec, version)
        if hit:
            bad_lines.append(i)
            kinds.update(hit)
    if invalid:
        raise HTTPError(400, "invalid_line", lines=invalid)
    if bad_lines:
        _COUNTERS["rejected_lines"] += len(bad_lines)
        _log(f"reject unmasked_secret host={host} kinds={','.join(sorted(kinds))}"
             f" lines={','.join(map(str, bad_lines[:50]))}")
        raise HTTPError(422, "unmasked_secret", lines=bad_lines, kinds=sorted(kinds))

    payload = "".join(line + "\n" for line in lines).encode("utf-8")
    sha = hashlib.sha256(payload).hexdigest()
    if sha != seg_sha:
        raise HTTPError(400, "sha256_mismatch")

    session_key = make_session_key(host, project_dir, key_sid)
    got = await _get_session(session_key)
    existing, seq, term = got if got else (None, None, None)
    if existing and existing.get("host") != host:
        raise HTTPError(403, "host_mismatch")
    chunks = list((existing or {}).get("archive_chunks") or [])
    cur_gen = (existing or {}).get("archive_generation")
    cur_gen = -1 if cur_gen is None else cur_gen
    seg_chunks = [c for c in _segment_chunks(chunks) if c.get("generation") == cur_gen]
    next_expected = max((c["end_offset"] for c in seg_chunks), default=0)
    new_generation = False
    if generation < cur_gen:
        raise HTTPError(409, "stale_generation", expected_offset=0, generation=cur_gen)
    if generation > cur_gen:
        if offset != 0:
            raise HTTPError(409, "offset_mismatch", expected_offset=0)
        new_generation = True
        seg_chunks = []
    elif offset != next_expected:
        if any(c["offset"] == offset for c in seg_chunks):
            # A retry of a segment already accepted: the same objects and ids
            # are rewritten, and anything after it is superseded.
            seg_chunks = [c for c in seg_chunks if c["offset"] < offset]
        else:
            raise HTTPError(409, "offset_mismatch", expected_offset=next_expected)

    parsed = sessions_parse.parse_lines(
        session_key, kind, lines, offset, host=host, session_id=session_id, agent_id=agent_id,
        known_entrypoint=(existing or {}).get("entrypoint"), redact_version=version)
    for k, n in parsed["counters"]["unknown_types"].items():
        _COUNTERS["unknown_types"][k] = _COUNTERS["unknown_types"].get(k, 0) + n

    # Step 6 (main only): the archive chunk.
    archive_state = "skipped"
    archived_chunk = False
    if kind == "main":
        backend = _archive_backend()
        if backend is not None:
            name = sessions_archive.object_name(host, session_key, generation=generation, offset=offset)
            try:
                await backend.put(name, sessions_archive.compress(payload))
            except sessions_archive.ArchiveError:
                raise HTTPError(503, "archive_unavailable") from None
            archive_state = "written"
            archived_chunk = True

    if new_generation and existing is not None:
        # A rewritten or truncated JSONL starts over (§8 row 5).
        await _delete_messages(session_key)
    # Step 5: bulk index, no refresh.
    await _bulk_index(MESSAGE_INDEX, parsed["docs"])

    delta = parsed["delta"]
    seg_chunks.append({
        "generation": generation, "offset": offset, "end_offset": end_offset,
        "sha256": sha, "bytes": len(payload), "archived": archived_chunk,
        "messages": delta["message_count"], "text_messages": delta["text_message_count"],
        "tombstones": delta["tombstones"],
    })
    seg_chunks.sort(key=lambda c: c["offset"])
    blobs = [] if new_generation else _blob_entries(chunks)
    doc = sessions_parse.merge_session(None if new_generation else existing, delta,
                                       project_dir=project_dir)
    is_main = kind == "main"
    all_archived = is_main and all(c.get("archived") for c in seg_chunks)
    doc.update({
        "session_key": session_key, "session_id": session_id, "host": host,
        "project_dir": project_dir, "jsonl_path": jsonl_path,
        "jsonl_exists": True, "jsonl_checked_at": _now_iso(),
        "message_count": sum(c["messages"] for c in seg_chunks),
        "text_message_count": sum(c["text_messages"] for c in seg_chunks),
        "has_subagents": bool((existing or {}).get("has_subagents")),
        "archived": all_archived,
        "archive_complete": all_archived and not any(c["tombstones"] for c in seg_chunks),
        "archive_generation": generation,
        "archive_bytes": sum(c["bytes"] for c in seg_chunks if c.get("archived")),
        "archive_chunks": seg_chunks + blobs,
        "redact_version": version,
    })
    if not doc.get("updated_at"):
        doc["updated_at"] = _now_iso()
    if existing and existing.get("restored_from"):
        doc["restored_from"] = existing["restored_from"]
    await _put_session(session_key, doc, seq, term)

    if kind == "subagent":
        parent_key = make_session_key(host, project_dir, parent_sid)
        await _update_session(parent_key, {"has_subagents": True}, upsert={
            "session_key": parent_key, "session_id": parent_sid, "host": host,
            "project_dir": project_dir, "has_subagents": True})

    _COUNTERS["ingested_segments"] += 1
    # Step 7: embeddings in the background.
    EMBED_SCHEDULER([d for d in parsed["docs"] if d.get("text")])
    return JSONResponse({"session_key": session_key, "indexed": len(parsed["docs"]),
                         "next_offset": end_offset, "archive": archive_state})


async def blob(request: Request, caller: dict):
    body = await _json_body(request)
    session_key = _session_key_param(body.get("session_key"))
    name = body.get("name")
    if not isinstance(name, str) or not TOOL_RESULT_NAME_RE.fullmatch(name):
        raise HTTPError(400, "invalid_name")
    sha = _str(body.get("sha256"), "sha256", SHA256_RE)
    content = body.get("content")
    if not isinstance(content, str):
        raise HTTPError(400, "invalid_request", field="content")
    src, seq, term = await _owned_session(session_key, caller)
    version = src.get("redact_version") or session_redact.RULESET_VERSION
    kinds = session_redact.detect_text(content, version)
    if kinds:
        _log(f"reject unmasked_secret blob host={src.get('host')} kinds={','.join(kinds)}")
        raise HTTPError(422, "unmasked_secret", lines=[], kinds=kinds)
    data = content.encode("utf-8")
    if hashlib.sha256(data).hexdigest() != sha:
        raise HTTPError(400, "sha256_mismatch")
    backend = _archive_backend()
    if backend is None:
        return JSONResponse({"stored": False, "reason": "archive_disabled"})
    obj = sessions_archive.object_name(src["host"], session_key, tool_result=name)
    try:
        await backend.put(obj, sessions_archive.compress(data))
    except sessions_archive.ArchiveError:
        raise HTTPError(503, "archive_unavailable") from None
    chunks = [c for c in src.get("archive_chunks") or [] if c.get("name") != name]
    chunks.append({"name": name, "sha256": sha, "bytes": len(data)})
    src = dict(src)
    src["archive_chunks"] = chunks
    await _put_session(session_key, src, seq, term)
    return JSONResponse({"stored": True})


async def state(request: Request, caller: dict):
    body = await _json_body(request)
    session_key = _session_key_param(body.get("session_key"))
    exists = body.get("jsonl_exists")
    if not isinstance(exists, bool):
        raise HTTPError(400, "invalid_request", field="jsonl_exists")
    await _owned_session(session_key, caller)
    await _update_session(session_key, {"jsonl_exists": exists, "jsonl_checked_at": _now_iso()})
    return JSONResponse({"ok": True})


async def _call_search(fn, *args):
    if fn is None:
        raise HTTPError(501, "not_implemented")
    try:
        res = fn(*args)
        if inspect.isawaitable(res):
            res = await res
    except ValueError as exc:
        raise HTTPError(400, "bad_request", detail=str(exc)[:200]) from None
    return JSONResponse(res)


async def search(request: Request, caller: dict):
    if sessions_search is None:
        raise HTTPError(501, "not_implemented")
    body = await _json_body(request)
    return await _call_search(sessions_search.search, be, body, caller)


async def preview(request: Request, caller: dict):
    if sessions_search is None:
        raise HTTPError(501, "not_implemented")
    session_key = _session_key_param(request.query_params.get("session_key"))
    q = request.query_params.get("q", "")
    return await _call_search(sessions_search.preview, be, session_key, q, caller)


async def _download_segments(src: dict) -> bytes:
    """Concatenate the highest generation's chunks in offset order, checking
    contiguity and each chunk's sha256 against ES (§6.5, §8 rows 12 / 19)."""
    if not src.get("archived"):
        raise HTTPError(404, "not_archived")
    if not src.get("archive_complete"):
        raise HTTPError(409, "archive_incomplete")
    segs = _segment_chunks(src.get("archive_chunks"))
    if not segs:
        raise HTTPError(404, "not_archived")
    gen = max(c["generation"] for c in segs)
    segs = sorted((c for c in segs if c["generation"] == gen), key=lambda c: c["offset"])
    expected = 0
    for c in segs:
        if c["offset"] != expected or not c.get("archived"):
            await _update_session(src["session_key"], {"archive_complete": False})
            raise HTTPError(409, "archive_incomplete")
        expected = c["end_offset"]
    backend = _archive_backend()
    if backend is None:
        raise HTTPError(503, "archive_unavailable")
    out = bytearray()
    for c in segs:
        name = sessions_archive.object_name(src["host"], src["session_key"],
                                            generation=gen, offset=c["offset"])
        try:
            data = sessions_archive.decompress(await backend.get(name))
        except sessions_archive.ArchiveNotFound:
            await _update_session(src["session_key"], {"archive_complete": False})
            raise HTTPError(409, "archive_incomplete") from None
        except sessions_archive.ArchiveUnavailable:
            raise HTTPError(503, "archive_unavailable") from None
        except sessions_archive.ArchiveError:
            raise HTTPError(409, "archive_tampered") from None
        if hashlib.sha256(data).hexdigest() != c["sha256"]:
            _log(f"archive_tampered session={src['session_key']} offset={c['offset']}")
            raise HTTPError(409, "archive_tampered")
        out += data
    return bytes(out)


async def archive(request: Request, caller: dict):
    session_key = _session_key_param(request.query_params.get("session_key"))
    got = await _get_session(session_key)
    if got is None:
        raise HTTPError(404, "not_found")
    data = await _download_segments(got[0])
    return Response(data, media_type="application/x-ndjson",
                    headers={"X-Archive-Sha256": hashlib.sha256(data).hexdigest()})


async def archive_tool_results(request: Request, caller: dict):
    session_key = _session_key_param(request.query_params.get("session_key"))
    got = await _get_session(session_key)
    if got is None:
        raise HTTPError(404, "not_found")
    src = got[0]
    entries = _blob_entries(src.get("archive_chunks"))
    backend = _archive_backend() if entries else None
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for e in sorted(entries, key=lambda x: x["name"]):
            if not TOOL_RESULT_NAME_RE.fullmatch(e["name"]):
                raise HTTPError(409, "archive_tampered")
            obj = sessions_archive.object_name(src["host"], session_key, tool_result=e["name"])
            try:
                data = sessions_archive.decompress(await backend.get(obj))
            except sessions_archive.ArchiveNotFound:
                raise HTTPError(409, "archive_incomplete") from None
            except sessions_archive.ArchiveUnavailable:
                raise HTTPError(503, "archive_unavailable") from None
            except sessions_archive.ArchiveError:
                raise HTTPError(409, "archive_tampered") from None
            if hashlib.sha256(data).hexdigest() != e["sha256"]:
                raise HTTPError(409, "archive_tampered")
            info = tarfile.TarInfo(e["name"])
            info.size = len(data)
            info.mode = 0o600
            tar.addfile(info, io.BytesIO(data))
    return Response(buf.getvalue(), media_type="application/x-tar")


async def delete_session(request: Request, caller: dict):
    session_key = _session_key_param(request.query_params.get("session_key"))
    # A host-less identity (the personal operator) may purge any host's
    # session; a host-bound one only its own (§7.2 writes rule).
    src, _, _ = await _owned_session(session_key, caller, allow_hostless=True)
    deleted_objects = 0
    backend = _archive_backend()
    if backend is not None:
        prefix = sessions_archive.object_name(src["host"], session_key)
        try:
            for name in await backend.list(prefix):
                if name.startswith(prefix):
                    await backend.delete(name)
                    deleted_objects += 1
        except sessions_archive.ArchiveError:
            raise HTTPError(503, "archive_unavailable") from None
    deleted_docs = await _delete_messages(session_key)
    r = await _es("DELETE", f"/{SESSION_INDEX}/_doc/{session_key}")
    if r.status_code not in (200, 404):
        raise ESUnavailable(f"delete session: {r.status_code}")
    deleted_docs += 1 if r.status_code == 200 else 0
    _log(f"purge session={session_key} host={src.get('host')} by={caller.get('agent')}"
         f" docs={deleted_docs} objects={deleted_objects}")
    return JSONResponse({"deleted_docs": deleted_docs, "deleted_objects": deleted_objects})


async def status(request: Request, caller: dict):
    out = {"schema": {"session": SCHEMA_SESSION, "message": SCHEMA_MESSAGE},
           "redact_version": session_redact.RULESET_VERSION,
           "parser_version": sessions_parse.PARSER_VERSION,
           "ready": _STATE["ready"], "docs": None, "sessions": None,
           "pending_embeddings": None, "last_retention_run": None,
           "caller_host": caller.get("host"),
           "unknown_types": dict(_COUNTERS["unknown_types"]),
           "rejected_lines": _COUNTERS["rejected_lines"],
           "search": sessions_search is not None}
    if not _STATE["ready"]:
        out["error"] = _STATE["error"]
        return JSONResponse(out)
    try:
        out["docs"] = await _count(MESSAGE_INDEX)
        out["sessions"] = await _count(SESSION_INDEX)
        out["pending_embeddings"] = await _count(
            MESSAGE_INDEX, {"term": {"embedding_status": "pending"}})
    except ESUnavailable:
        pass
    return JSONResponse(out)


HANDLERS = {
    ("POST", "/ingest"): ingest,
    ("POST", "/blob"): blob,
    ("POST", "/state"): state,
    ("POST", "/search"): search,
    ("GET", "/preview"): preview,
    ("GET", "/archive"): archive,
    ("GET", "/archive/tool-results"): archive_tool_results,
    ("DELETE", "/session"): delete_session,
    ("GET", "/status"): status,
}
assert set(HANDLERS) == set(ROUTES)  # noqa: S101 — import-time invariant


# --------------------------------------------------------------------------- #
# Gate + dispatch (pure ASGI)
# --------------------------------------------------------------------------- #
def _route_path(scope) -> str:
    """Path relative to the mount point. Starlette versions differ in whether a
    Mount passes the full path (with root_path set) or the remainder."""
    path = scope.get("path", "")
    root = scope.get("root_path", "")
    if root and path.startswith(root):
        path = path[len(root):]
    return path


def gate(scope, headers) -> tuple:
    """(caller | None, error JSONResponse | None). Pure apart from audit lines;
    exposed for tests."""
    if not identity.proxy_secret_configured():
        return None, _err(403, "gate_unconfigured")
    try:
        identity.require_proxy_secret(headers)
        ident = identity.parse_identity(headers)
    except identity.ProxyAuthError:
        return None, _err(401, "unauthenticated")
    key = (scope.get("method", ""), _route_path(scope))
    raw = scope.get("raw_path") or b""
    if isinstance(raw, bytes):
        low = raw.split(b"?", 1)[0].lower()
        # An encoded separator or a dot segment never names a route: refuse it
        # instead of letting the decoded path resolve to one (§8 row 23).
        if b"%2f" in low or b"%5c" in low or b"%2e" in low or any(
                seg in (b".", b"..") for seg in low.split(b"/")):
            return None, _err(403, "forbidden")
    scope_name = ROUTES.get(key)
    if scope_name is None:
        return None, _err(403, "forbidden")
    ok, host = identity.authorize_session_scope(ident, scope_name)
    if not ok:
        print(f"AUDIT sessions_deny route={identity._audit_token(key[1])}"
              f" client={identity._audit_token(ident.get('client_id'))}"
              f" grant={identity._audit_token(ident.get('grant'))}", file=sys.stderr, flush=True)
        return None, _err(403, "forbidden")
    return {**ident, "host": host, "scope": scope_name}, None


async def app(scope, receive, send):
    if scope["type"] == "lifespan":
        # Mounted: the parent runs the lifespan; answer a direct one politely.
        while True:
            msg = await receive()
            if msg["type"] == "lifespan.startup":
                await send({"type": "lifespan.startup.complete"})
            elif msg["type"] == "lifespan.shutdown":
                await send({"type": "lifespan.shutdown.complete"})
                return
    if scope["type"] != "http":
        return
    request = Request(scope, receive)
    caller, denied = gate(scope, request.headers)
    if denied is not None:
        await denied(scope, receive, send)
        return
    key = (scope["method"], _route_path(scope))
    if not _STATE["ready"] and key != ("GET", "/status"):
        response = _err(503, "index_unavailable")
    else:
        try:
            response = await HANDLERS[key](request, caller)
        except HTTPError as exc:
            response = _err(exc.status, exc.code, **exc.extra)
        except sessions_archive.InvalidName:
            response = _err(400, "invalid_name")
        except ESUnavailable as exc:
            _log(f"es unavailable route={key[1]} error={exc}")
            response = _err(503, "es_unavailable")
    await response(scope, receive, send)
