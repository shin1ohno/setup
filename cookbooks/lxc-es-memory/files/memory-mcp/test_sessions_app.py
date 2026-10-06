#!/usr/bin/env python3
"""sessions_app end-to-end over Starlette's TestClient, hermetic.

ES is an in-memory fake installed as the `es_backend` module before import, and
the archive is sessions_archive.MemoryBackend, so nothing leaves the process.
Needs the memory-mcp venv (starlette, httpx, zstandard):

    /tmp/memory-mcp-venv/bin/python test_sessions_app.py

Covers the gate (proxy secret, unknown routes, memory-mirror, scopes, host
mismatch), body limits (9 MiB, gzip bomb), the 422 re-scan, offsets and
generations, session_key opacity and object-name validation, archive download
with tampered / missing chunks, blobs, purge, status, the 501 search fallback,
and that the in-process index definitions equal the committed JSON.
"""

from __future__ import annotations

import asyncio
import gzip
import hashlib
import io
import json
import os
import re
import sys
import tarfile
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

SECRET = "proxy-secret-for-tests"
POLICY = {"rules": [
    {"match": {"grant": "client_credentials", "client_id": "session-search-pro-dev"},
     "host": "pro-dev", "scopes": ["sessions:ingest", "sessions:read"]},
    {"match": {"grant": "authorization_code", "client_id": "tailnet:nXXXX"},
     "host": "air", "scopes": ["sessions:ingest", "sessions:read", "sessions:purge"]},
    {"match": {"grant": "authorization_code", "sub": "operator@example.com"},
     "host": None, "scopes": ["sessions:read", "sessions:purge"]},
]}
os.environ["PROXY_SHARED_SECRET"] = SECRET
os.environ["SESSION_SCOPE_POLICY"] = json.dumps(POLICY)
for k in ("SESSION_ARCHIVE_BACKEND", "SESSION_ARCHIVE_BUCKET"):
    os.environ.pop(k, None)


# --------------------------------------------------------------------------- #
# Fake ES (the subset of the REST API sessions_app uses)
# --------------------------------------------------------------------------- #
class FakeResp:
    def __init__(self, status, payload=None):
        self.status_code = status
        self._payload = payload if payload is not None else {}
        self.text = json.dumps(self._payload)

    def json(self):
        return self._payload


class FakeES:
    def __init__(self):
        self.indices: dict[str, dict] = {}
        self.seq = 0
        self.calls: list = []
        self.created: dict = {}
        self.fail_put = None

    def _idx(self, name):
        return self.indices.setdefault(name, {})

    async def request(self, method, path, json=None, content=None, headers=None):  # noqa: A002
        self.calls.append((method, path))
        base, _, query = path.partition("?")
        parts = base.strip("/").split("/")
        if method == "POST" and parts == ["_bulk"]:
            lines = content.strip().split("\n")
            items = []
            for meta, src in zip(lines[::2], lines[1::2]):
                m = __import__("json").loads(meta)["index"]
                self.seq += 1
                self._idx(m["_index"])[m["_id"]] = (__import__("json").loads(src), self.seq)
                items.append({"index": {"_id": m["_id"], "status": 201}})
            self.calls[-1] = (method, path, query)
            return FakeResp(200, {"errors": False, "items": items})
        index = parts[0]
        if len(parts) == 3 and parts[1] == "_doc":
            docs = self._idx(index)
            did = parts[2]
            if method == "GET":
                if did not in docs:
                    return FakeResp(404, {"found": False})
                src, seq = docs[did]
                return FakeResp(200, {"found": True, "_source": __import__("copy").deepcopy(src),
                                      "_seq_no": seq, "_primary_term": 1})
            if method == "PUT":
                if "if_seq_no" in query:
                    want = int(re.search(r"if_seq_no=(\d+)", query).group(1))
                    if did not in docs or docs[did][1] != want:
                        return FakeResp(409, {})
                self.seq += 1
                docs[did] = (__import__("copy").deepcopy(json), self.seq)
                return FakeResp(200, {})
            if method == "DELETE":
                if did in docs:
                    del docs[did]
                    return FakeResp(200, {})
                return FakeResp(404, {})
        if len(parts) == 3 and parts[1] == "_update" and method == "POST":
            docs = self._idx(index)
            did = parts[2]
            self.seq += 1
            if did in docs:
                src = dict(docs[did][0])
                src.update(json["doc"])
                docs[did] = (src, self.seq)
                return FakeResp(200, {})
            if "upsert" in json:
                docs[did] = (dict(json["upsert"]), self.seq)
                return FakeResp(201, {})
            return FakeResp(404, {})
        if len(parts) == 2 and parts[1] == "_delete_by_query":
            sk = json["query"]["term"]["session_key"]
            docs = self._idx(index)
            gone = [k for k, (s, _) in docs.items() if s.get("session_key") == sk]
            for k in gone:
                del docs[k]
            return FakeResp(200, {"deleted": len(gone)})
        if len(parts) == 2 and parts[1] == "_count":
            docs = self._idx(index)
            q = json["query"]
            if "term" in q:
                (f, v), = q["term"].items()
                n = sum(1 for s, _ in docs.values() if s.get(f) == v)
            else:
                n = len(docs)
            return FakeResp(200, {"count": n})
        if len(parts) == 1 and method == "PUT":
            if index in self.created:
                return FakeResp(400, {"error": {"type": "resource_already_exists_exception"}})
            self.created[index] = json
            return FakeResp(200, {})
        if len(parts) == 2 and parts[1] == "_mapping":
            body = self.created.get(index)
            if body is None:
                return FakeResp(404, {})
            return FakeResp(200, {index: {"mappings": body["mappings"]}})
        if len(parts) == 1 and method == "HEAD":
            return FakeResp(200 if index in self.created else 404)
        raise AssertionError(f"unexpected ES call {method} {path}")

    async def __aenter__(self):
        return self

    async def __aexit__(self, *a):
        return False


FAKE = FakeES()
_be = types.ModuleType("es_backend")
_be._es = FAKE
_be._make_client = lambda: FAKE


async def _index_exists(client, name):
    return name in FAKE.created


_be._index_exists = _index_exists
with open(os.path.join(HERE, "..", "es-indices-v2", "memory-knowledge.json")) as _fh:
    _be._ANALYSIS = json.load(_fh)["settings"]["analysis"]
sys.modules["es_backend"] = _be

from starlette.applications import Starlette  # noqa: E402
from starlette.routing import Mount  # noqa: E402
from starlette.testclient import TestClient  # noqa: E402

import identity  # noqa: E402
import session_redact  # noqa: E402
import sessions_app as sa  # noqa: E402
import sessions_archive as arc  # noqa: E402
import sessions_parse  # noqa: E402

PREFIX = "/memory/sessions/v1"
APP = Starlette(routes=[Mount(PREFIX, app=sa.app)])
KEY = b"hmac-key-for-tests"

PRO_DEV = {"x-verified-grant": "client_credentials", "x-verified-client-id": "session-search-pro-dev",
           "x-verified-sub": "session-search-pro-dev", "x-proxy-secret": SECRET}
AIR = {"x-verified-grant": "authorization_code", "x-verified-client-id": "tailnet:nXXXX",
       "x-verified-sub": "human", "x-proxy-secret": SECRET}
OPERATOR = {"x-verified-grant": "authorization_code", "x-verified-client-id": "claude-ai",
            "x-verified-sub": "operator@example.com", "x-proxy-secret": SECRET}
MIRROR = {"x-verified-grant": "client_credentials", "x-verified-client-id": "memory-mirror",
          "x-verified-sub": "memory-mirror", "x-proxy-secret": SECRET}

SID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
PDIR = "-home-dev-proj"
ALL_ROUTES = [(m, p) for (m, p) in sa.ROUTES]


def line(uuid, text, ts="2026-10-01T10:00:00Z", **kw):
    r = {"type": "user", "uuid": uuid, "sessionId": SID, "cwd": "/home/dev/proj",
         "entrypoint": "cli", "timestamp": ts, "message": {"role": "user", "content": text}}
    r.update(kw)
    return json.dumps(r, ensure_ascii=False, separators=(",", ":"))


def segment_body(lines, offset, end_offset=None, generation=0, host="pro-dev", sid=SID,
                 kind="main", pdir=PDIR, version="r1", **file_extra):
    payload = "".join(x + "\n" for x in lines).encode()
    return {
        "client": {"host": host, "client_version": "test", "redact_version": version},
        "file": {"session_id": sid, "project_dir": pdir, "jsonl_path": f"/x/{sid}.jsonl",
                 "kind": kind, **file_extra},
        "segment": {"generation": generation, "offset": offset,
                    "end_offset": end_offset if end_offset is not None else offset + len(payload),
                    "sha256": hashlib.sha256(payload).hexdigest(), "lines": lines},
    }


def gz(obj):
    return gzip.compress(json.dumps(obj).encode())


class Base(unittest.TestCase):
    def setUp(self):
        FAKE.indices.clear()
        FAKE.calls.clear()
        self.store = arc.MemoryBackend()
        sa._ARCHIVE.clear()
        sa._ARCHIVE["backend"] = self.store
        sa._STATE["ready"] = True
        self.embedded = []
        sa.EMBED_SCHEDULER = self.embedded.extend
        self.c = TestClient(APP)

    def ingest(self, body, headers=PRO_DEV, raw=None):
        return self.c.post(PREFIX + "/ingest", content=raw if raw is not None else gz(body),
                           headers={**headers, "content-type": "application/json"})

    def session(self, sk):
        return FAKE.indices["memory-session"][sk][0]


class Gate(Base):
    def test_missing_or_wrong_proxy_secret_is_401(self):
        for h in ({k: v for k, v in PRO_DEV.items() if k != "x-proxy-secret"},
                  {**PRO_DEV, "x-proxy-secret": "wrong"}):
            r = self.c.get(PREFIX + "/status", headers=h)
            self.assertEqual(r.status_code, 401, r.text)

    def test_unconfigured_secret_refuses_everything(self):
        saved = identity._PROXY_SHARED_SECRET
        identity._PROXY_SHARED_SECRET = ""
        try:
            r = self.c.get(PREFIX + "/status", headers=PRO_DEV)
            self.assertEqual((r.status_code, r.json()["error"]), (403, "gate_unconfigured"))
        finally:
            identity._PROXY_SHARED_SECRET = saved

    def test_unknown_routes_are_403(self):
        for method, path in (("GET", "/nope"), ("GET", "/status/"), ("HEAD", "/status"),
                             ("POST", "/status"), ("GET", "/ingest"), ("PUT", "/session"),
                             ("GET", "/archive%2Ftool-results"), ("GET", "")):
            with self.subTest(method=method, path=path):
                r = self.c.request(method, PREFIX + path, headers=AIR)
                self.assertEqual(r.status_code, 403, (path, r.text))

    def test_dot_segments_and_encoded_separators_in_raw_path_are_403(self):
        # httpx resolves dot segments client-side, so drive the gate directly
        # with the raw_path a hostile client (or proxy) could send.
        headers = {k: v for k, v in AIR.items()}
        for raw in (b"/memory/sessions/v1/x/../status", b"/memory/sessions/v1/./status",
                    b"/memory/sessions/v1/archive%2Ftool-results", b"/memory/sessions/v1/%2e%2e/status",
                    b"/memory/sessions/v1/status%5c"):
            with self.subTest(raw=raw):
                scope = {"method": "GET", "path": "/memory/sessions/v1/status",
                         "root_path": "/memory/sessions/v1", "raw_path": raw}
                caller, denied = sa.gate(scope, headers)
                self.assertIsNone(caller)
                self.assertEqual(denied.status_code, 403)
        scope = {"method": "GET", "path": "/memory/sessions/v1/status",
                 "root_path": "/memory/sessions/v1", "raw_path": b"/memory/sessions/v1/status"}
        caller, denied = sa.gate(scope, headers)
        self.assertIsNone(denied)
        self.assertEqual((caller["host"], caller["scope"]), ("air", "sessions:read"))

    def test_memory_mirror_is_403_everywhere(self):
        for method, path in ALL_ROUTES:
            with self.subTest(route=path):
                r = self.c.request(method, PREFIX + path, headers=MIRROR)
                self.assertEqual(r.status_code, 403, r.text)

    def test_no_identity_is_403(self):
        r = self.c.get(PREFIX + "/status", headers={"x-proxy-secret": SECRET})
        self.assertEqual(r.status_code, 403)

    def test_scope_is_enforced_per_route(self):
        # pro-dev has no purge scope; the operator has no ingest scope
        r = self.c.delete(PREFIX + "/session", params={"session_key": "sk_" + "a" * 32},
                          headers=PRO_DEV)
        self.assertEqual(r.status_code, 403)
        r = self.ingest(segment_body([line("u1", "hi")], 0), headers=OPERATOR)
        self.assertEqual(r.status_code, 403)

    def test_policy_unset_denies_all(self):
        saved = identity._SESSION_SCOPE_POLICY
        identity._SESSION_SCOPE_POLICY = None
        try:
            for h in (PRO_DEV, AIR, OPERATOR):
                self.assertEqual(self.c.get(PREFIX + "/status", headers=h).status_code, 403)
        finally:
            identity._SESSION_SCOPE_POLICY = saved

    def test_status_reports_caller_host(self):
        r = self.c.get(PREFIX + "/status", headers=PRO_DEV)
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(r.json()["caller_host"], "pro-dev")
        self.assertEqual(r.json()["redact_version"], "r1")
        self.assertIsNone(self.c.get(PREFIX + "/status", headers=OPERATOR).json()["caller_host"])

    def test_not_ready_is_503_except_status(self):
        sa._STATE["ready"] = False
        r = self.ingest(segment_body([line("u1", "hi")], 0))
        self.assertEqual((r.status_code, r.json()["error"]), (503, "index_unavailable"))
        self.assertEqual(self.c.get(PREFIX + "/status", headers=PRO_DEV).status_code, 200)

    def test_search_and_preview_501_without_module(self):
        if sa.sessions_search is not None:
            self.skipTest("sessions_search is installed")
        r = self.c.post(PREFIX + "/search", json={"q": "x"}, headers=PRO_DEV)
        self.assertEqual((r.status_code, r.json()["error"]), (501, "not_implemented"))
        r = self.c.get(PREFIX + "/preview", params={"session_key": "sk_" + "a" * 32, "q": "x"},
                       headers=PRO_DEV)
        self.assertEqual(r.status_code, 501)
        self.assertEqual(self.c.post(PREFIX + "/search", json={}, headers=MIRROR).status_code, 403)


class Limits(Base):
    def test_9_mib_body_is_413(self):
        r = self.ingest(None, raw=b"x" * (9 * 1024 * 1024))
        self.assertEqual((r.status_code, r.json()["error"]), (413, "too_large"))

    def test_9_mib_body_without_content_length_is_413(self):
        def gen():
            for _ in range(9):
                yield b"x" * (1024 * 1024)
        r = self.c.post(PREFIX + "/ingest", content=gen(), headers=PRO_DEV)
        self.assertEqual(r.status_code, 413)

    def test_gzip_bomb_is_413(self):
        bomb = gzip.compress(b"\0" * (6 * 1024 * 1024), compresslevel=9)
        self.assertLess(len(bomb), 16 * 1024)
        r = self.ingest(None, raw=bomb)
        self.assertEqual((r.status_code, r.json()["error"]), (413, "too_large"))

    def test_truncated_gzip_is_400(self):
        r = self.ingest(None, raw=gz({"a": 1})[:-6])
        self.assertEqual(r.status_code, 400)


class Ingest(Base):
    def test_happy_path(self):
        lines = [line("u1", "find the worktree bug"),
                 json.dumps({"type": "ai-title", "aiTitle": "Worktree bug"})]
        r = self.ingest(segment_body(lines, 0))
        self.assertEqual(r.status_code, 200, r.text)
        out = r.json()
        sk = out["session_key"]
        self.assertEqual(out["archive"], "written")
        self.assertEqual(out["indexed"], 1)
        self.assertRegex(sk, r"^sk_[a-z2-7]{32}$")
        self.assertEqual(sk, sa.make_session_key("pro-dev", PDIR, SID))
        self.assertNotIn(SID.replace("-", ""), sk)
        s = self.session(sk)
        self.assertEqual((s["host"], s["title"], s["resume_cwd"]), ("pro-dev", "Worktree bug",
                                                                    "/home/dev/proj"))
        self.assertTrue(s["resume_cwd_verified"] and s["archived"] and s["archive_complete"])
        self.assertEqual(s["message_count"], 1)
        # no refresh on the bulk call
        bulk = [c for c in FAKE.calls if c[1].startswith("/_bulk")]
        self.assertTrue(bulk and all("refresh" not in c[1] for c in bulk))
        self.assertEqual([d["uuid"] for d in self.embedded], ["u1"])
        mapping = sa.index_definitions()["memory-session"][0]["mappings"]["properties"]
        self.assertLessEqual(set(s), set(mapping), set(s) - set(mapping))
        mmap = sa.index_definitions()["memory-session-message"][0]["mappings"]["properties"]
        for src, _ in FAKE.indices["memory-session-message"].values():
            self.assertLessEqual(set(src), set(mmap), set(src) - set(mmap))

    def test_body_host_must_match_identity(self):
        r = self.ingest(segment_body([line("u1", "x")], 0, host="mini"))
        self.assertEqual((r.status_code, r.json()["error"]), (403, "host_mismatch"))
        r = self.ingest(segment_body([line("u1", "x")], 0, host="air"))
        self.assertEqual(r.status_code, 403)

    def test_write_to_another_hosts_session_is_403(self):
        r = self.ingest(segment_body([line("u1", "x")], 0, host="air"), headers=AIR)
        sk = r.json()["session_key"]
        r = self.c.post(PREFIX + "/state", json={"session_key": sk, "jsonl_exists": False},
                        headers=PRO_DEV)
        self.assertEqual((r.status_code, r.json()["error"]), (403, "host_mismatch"))
        r = self.c.post(PREFIX + "/blob", content=gz({"session_key": sk, "name": "a.txt",
                                                      "sha256": "0" * 64, "content": "x"}),
                        headers=PRO_DEV)
        self.assertEqual(r.status_code, 403)
        r = self.c.post(PREFIX + "/state", json={"session_key": sk, "jsonl_exists": False},
                        headers=AIR)
        self.assertEqual(r.status_code, 200)
        self.assertFalse(self.session(sk)["jsonl_exists"])

    def test_unmasked_secret_is_422_with_line_indexes(self):
        tok = "ghp_" + "A" * 36
        lines = [line("u1", "fine"), line("u2", f"oops {tok}"), line("u3", "fine"),
                 line("u4", "DB_PASSWORD=hunter2hunter2")]
        r = self.ingest(segment_body(lines, 0))
        self.assertEqual(r.status_code, 422, r.text)
        self.assertEqual(r.json(), {"error": "unmasked_secret", "lines": [1, 3],
                                    "kinds": ["config-secret", "github-token"]})
        self.assertNotIn(tok, r.text)
        self.assertNotIn("memory-session", FAKE.indices)

    def test_masked_input_passes_rescan(self):
        rec = json.loads(line("u2", "token ghp_" + "A" * 36 + " and Authorization: Bearer "
                              + "z" * 30))
        masked, counts = session_redact.redact_record(rec, KEY)
        r = self.ingest(segment_body([json.dumps(masked)], 0))
        self.assertEqual(r.status_code, 200, r.text)

    def test_tombstone_marks_archive_incomplete(self):
        tomb = json.dumps({"type": "session-search-tombstone", "reason": "unmasked_secret",
                           "kinds": ["jwt"], "line_offset": 10})
        r = self.ingest(segment_body([line("u1", "x"), tomb], 0))
        self.assertEqual(r.status_code, 200, r.text)
        s = self.session(r.json()["session_key"])
        self.assertFalse(s["archive_complete"])
        r = self.c.get(PREFIX + "/archive", params={"session_key": s["session_key"]}, headers=AIR)
        self.assertEqual((r.status_code, r.json()["error"]), (409, "archive_incomplete"))

    def test_validation(self):
        bad = [
            segment_body([line("u1", "x")], 0, sid="../../etc/passwd"),
            segment_body([line("u1", "x")], 0, pdir="../x"),
            segment_body([line("u1", "x")], 0, pdir="a/b"),
            segment_body([line("u1", "x")], 0, kind="other"),
            segment_body([line("u1", "x")], 0, version="r9"),
            segment_body([], 0),
        ]
        for b in bad:
            with self.subTest(b=b["file"]):
                self.assertEqual(self.ingest(b).status_code, 400)
        b = segment_body([line("u1", "x")], 0)
        b["segment"]["sha256"] = "0" * 64
        r = self.ingest(b)
        self.assertEqual((r.status_code, r.json()["error"]), (400, "sha256_mismatch"))

    def test_offsets_and_retries(self):
        b1 = segment_body([line("u1", "one")], 0)
        r1 = self.ingest(b1)
        end1 = r1.json()["next_offset"]
        r = self.ingest(segment_body([line("u2", "two")], end1 + 50))
        self.assertEqual((r.status_code, r.json()["expected_offset"]), (409, end1))
        r = self.ingest(segment_body([line("u2", "two")], 7))
        self.assertEqual(r.status_code, 409)
        self.assertEqual(self.ingest(b1).status_code, 200)  # retry of an accepted segment
        r2 = self.ingest(segment_body([line("u2", "two")], end1))
        self.assertEqual(r2.status_code, 200, r2.text)
        s = self.session(r1.json()["session_key"])
        self.assertEqual([c["offset"] for c in s["archive_chunks"]], [0, end1])
        self.assertEqual(s["message_count"], 2)

    def test_generation_bump_starts_over(self):
        r = self.ingest(segment_body([line("u1", "one"), line("u2", "two")], 0))
        sk = r.json()["session_key"]
        self.assertEqual(len(FAKE.indices["memory-session-message"]), 2)
        r = self.ingest(segment_body([line("u9", "new")], 40, generation=1))
        self.assertEqual((r.status_code, r.json()["expected_offset"]), (409, 0))
        r = self.ingest(segment_body([line("u9", "new")], 0, generation=1))
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual([s["uuid"] for s, _ in FAKE.indices["memory-session-message"].values()],
                         ["u9"])
        s = self.session(sk)
        self.assertEqual((s["archive_generation"], s["message_count"]), (1, 1))
        r = self.ingest(segment_body([line("u1", "old")], 0, generation=0))
        self.assertEqual((r.status_code, r.json()["error"]), (409, "stale_generation"))
        dl = self.c.get(PREFIX + "/archive", params={"session_key": sk}, headers=PRO_DEV)
        self.assertEqual(dl.text, line("u9", "new") + "\n")

    def test_subagent_has_own_key_and_flags_parent(self):
        main = self.ingest(segment_body([line("u1", "parent")], 0)).json()
        r = self.ingest(segment_body([line("s1", "child", isSidechain=True)], 0, kind="subagent",
                                     parent_session_id=SID, agent_id="a1b2"))
        self.assertEqual(r.status_code, 200, r.text)
        out = r.json()
        self.assertNotEqual(out["session_key"], main["session_key"])
        self.assertEqual(out["archive"], "skipped")
        self.assertTrue(self.session(main["session_key"])["has_subagents"])
        sub = self.session(out["session_key"])
        self.assertFalse(sub["archived"])
        child = [s for s, _ in FAKE.indices["memory-session-message"].values() if s["uuid"] == "s1"]
        self.assertTrue(child[0]["is_sidechain"])

    def test_archive_disabled_is_skipped(self):
        sa._ARCHIVE["backend"] = None
        r = self.ingest(segment_body([line("u1", "x")], 0))
        self.assertEqual(r.json()["archive"], "skipped")
        s = self.session(r.json()["session_key"])
        self.assertFalse(s["archived"])

    def test_archive_outage_is_503_and_holds_the_cursor(self):
        class Down(arc.MemoryBackend):
            async def put(self, name, data):
                raise arc.ArchiveUnavailable("down")
        sa._ARCHIVE["backend"] = Down()
        r = self.ingest(segment_body([line("u1", "x")], 0))
        self.assertEqual((r.status_code, r.json()["error"]), (503, "archive_unavailable"))
        self.assertFalse(FAKE.indices.get("memory-session"))
        self.assertFalse(FAKE.indices.get("memory-session-message"))


class Hostile(Base):
    """Parser-differential, ReDoS and event-loop findings from the security
    review: what is archived and indexed is exactly what the detector saw."""

    def test_invalid_lines_are_422_per_line(self):
        cases = {
            "duplicate-key": '{"type":"user","uuid":"d","message":{"content":"a"},"message":{"content":"b"}}',
            "surrogate": '{"type":"user","uuid":"s","message":{"content":"\\ud800x"}}',
            "non-finite-number": '{"type":"user","uuid":"n","x":NaN}',
            "invalid-json": "not json",
            "not-an-object": "[1,2]",
            "too-deep": '{"a":' * 70 + "1" + "}" * 70,
        }
        for kind, bad in cases.items():
            with self.subTest(kind=kind):
                r = self.ingest(segment_body([line("u1", "ok"), bad], 0))
                self.assertEqual(r.status_code, 422, r.text)
                self.assertEqual(r.json(), {"error": "invalid_line", "lines": [1], "kinds": [kind]})

    def test_secret_and_invalid_lines_are_reported_together(self):
        r = self.ingest(segment_body([line("u1", "ghp_" + "A" * 36), "nope", line("u3", "ok")], 0))
        self.assertEqual(r.status_code, 422)
        self.assertEqual(r.json(), {"error": "unmasked_secret", "lines": [0, 1],
                                    "kinds": ["github-token", "invalid-json"]})

    def test_secret_in_a_dict_key_is_rejected(self):
        bad = json.dumps({"type": "user", "uuid": "k", "toolUseResult": {"ghp_" + "A" * 36: 1}})
        r = self.ingest(segment_body([bad], 0))
        self.assertEqual((r.status_code, r.json()["kinds"]), (422, ["github-token"]))

    def test_archive_holds_the_canonical_form_of_what_was_scanned(self):
        rec = {"type": "user", "uuid": "c1", "cwd": "/home/dev/proj",
               "message": {"role": "user", "content": "line\u2028sep and \u0000 nul\r\nend"}}
        spaced = json.dumps(rec, ensure_ascii=False)  # ", " / ": " separators, raw U+2028
        self.assertIn("\u2028", spaced)
        r = self.ingest(segment_body([spaced], 0))
        self.assertEqual(r.status_code, 200, r.text)
        sk = r.json()["session_key"]
        dl = self.c.get(PREFIX + "/archive", params={"session_key": sk}, headers=AIR).content
        self.assertEqual(dl.decode(), sa.canonical_line(rec) + "\n")
        self.assertNotIn("\u2028".encode(), dl)
        self.assertNotIn(b"\r", dl)
        self.assertNotIn(b"\0", dl)
        self.assertEqual(dl.count(b"\n"), 1)
        self.assertEqual(json.loads(dl), rec)
        chunk = self.session(sk)["archive_chunks"][0]
        self.assertEqual(chunk["sha256"], hashlib.sha256(dl).hexdigest())
        doc = next(iter(FAKE.indices["memory-session-message"].values()))[0]
        self.assertEqual(doc["text"], rec["message"]["content"].strip())

    def test_jsonl_path_is_scanned_and_printable(self):
        for p in ("/x/ghp_" + "A" * 36 + ".jsonl", "/x/a\nb.jsonl", "/x/\x00.jsonl"):
            with self.subTest(p=p):
                b = segment_body([line("u1", "x")], 0)
                b["file"]["jsonl_path"] = p
                self.assertEqual(self.ingest(b).status_code, 400)

    def test_deeply_nested_request_body_is_400(self):
        r = self.ingest(None, raw=gzip.compress(b"[" * 200_000 + b"]" * 200_000))
        self.assertEqual((r.status_code, r.json()["error"]), (400, "bad_json"))

    def test_surrogate_blob_is_422(self):
        sk = self.ingest(segment_body([line("u1", "x")], 0)).json()["session_key"]
        raw = ('{"session_key":"%s","name":"a.txt","sha256":"%s","content":"\\ud800"}'
               % (sk, "0" * 64)).encode()
        r = self.c.post(PREFIX + "/blob", content=gzip.compress(raw), headers=PRO_DEV)
        self.assertEqual((r.status_code, r.json()["kinds"]), (422, ["surrogate"]))

    def test_hostile_segment_is_bounded_and_does_not_block_the_loop(self):
        """A segment that costs well over the budget is cut off with 413, and a
        cheap request issued while it runs completes promptly."""
        import time as _t

        import httpx
        hostile = 'token=eyJ-a://xx_sk-"secret": "' * 6000  # ~190 KB of worst-case text
        lines = [json.dumps({"type": "user", "uuid": f"h{i}", "message": {"content": hostile}})
                 for i in range(18)]
        body = gz(segment_body(lines, 0))

        async def run():
            transport = httpx.ASGITransport(app=APP)
            async with httpx.AsyncClient(transport=transport, base_url="http://t") as client:
                t0 = _t.monotonic()
                slow = asyncio.ensure_future(client.post(
                    PREFIX + "/ingest", content=body, headers=PRO_DEV))
                await asyncio.sleep(0.3)
                t1 = _t.monotonic()
                st = await client.get(PREFIX + "/status", headers=PRO_DEV)
                status_latency = _t.monotonic() - t1
                done_before = slow.done()
                res = await slow
                return res, st, status_latency, done_before, _t.monotonic() - t0

        res, st, status_latency, done_before, total = asyncio.run(run())
        self.assertEqual(st.status_code, 200)
        self.assertFalse(done_before, "the hostile segment should still be running")
        self.assertLess(status_latency, 1.0)
        self.assertEqual((res.status_code, res.json()["error"]), (413, "too_expensive"))
        self.assertLess(total, sa.SEGMENT_BUDGET_S + 3.0)


class Archive(Base):
    def two_segments(self):
        l1, l2 = [line("u1", "one")], [line("u2", "two")]
        r1 = self.ingest(segment_body(l1, 0)).json()
        self.ingest(segment_body(l2, r1["next_offset"]))
        return r1["session_key"], l1 + l2

    def test_download_roundtrip(self):
        sk, lines = self.two_segments()
        r = self.c.get(PREFIX + "/archive", params={"session_key": sk}, headers=AIR)
        self.assertEqual(r.status_code, 200, r.text)
        body = "".join(x + "\n" for x in lines)
        self.assertEqual(r.text, body)
        self.assertEqual(r.headers["x-archive-sha256"], hashlib.sha256(body.encode()).hexdigest())
        self.assertTrue(r.headers["content-type"].startswith("application/x-ndjson"))
        names = sorted(self.store.objects)
        self.assertTrue(all(n.startswith(f"sessions/pro-dev/{sk}/g0/") for n in names), names)
        self.assertTrue(names[0].endswith("/000000000000.jsonl.zst"))

    def test_tampered_chunk_is_409(self):
        sk, _ = self.two_segments()
        name = sorted(self.store.objects)[1]
        self.store.objects[name] = arc.compress(b'{"type":"user","forged":true}\n')
        r = self.c.get(PREFIX + "/archive", params={"session_key": sk}, headers=AIR)
        self.assertEqual((r.status_code, r.json()["error"]), (409, "archive_tampered"))
        self.store.objects[name] = b"not zstd"
        r = self.c.get(PREFIX + "/archive", params={"session_key": sk}, headers=AIR)
        self.assertEqual((r.status_code, r.json()["error"]), (409, "archive_tampered"))

    def test_gap_is_409_incomplete(self):
        sk, _ = self.two_segments()
        src, seq = FAKE.indices["memory-session"][sk]
        src["archive_chunks"] = [c for c in src["archive_chunks"] if c["offset"] != 0]
        r = self.c.get(PREFIX + "/archive", params={"session_key": sk}, headers=AIR)
        self.assertEqual((r.status_code, r.json()["error"]), (409, "archive_incomplete"))
        self.assertFalse(self.session(sk)["archive_complete"])

    def test_missing_object_is_409_incomplete(self):
        sk, _ = self.two_segments()
        del self.store.objects[sorted(self.store.objects)[0]]
        r = self.c.get(PREFIX + "/archive", params={"session_key": sk}, headers=AIR)
        self.assertEqual((r.status_code, r.json()["error"]), (409, "archive_incomplete"))

    def test_bad_session_keys(self):
        for v in ("../../x", "sk_..%2F..", "sk_" + "A" * 32, "sk_" + "a" * 31, "", "sk_a/b"):
            with self.subTest(v=v):
                r = self.c.get(PREFIX + "/archive", params={"session_key": v}, headers=AIR)
                self.assertEqual(r.status_code, 400, r.text)
        r = self.c.get(PREFIX + "/archive", params={"session_key": "sk_" + "a" * 32}, headers=AIR)
        self.assertEqual(r.status_code, 404)

    def test_blob_and_tool_results_tar(self):
        sk, _ = self.two_segments()
        content = "masked tool output"
        ok = {"session_key": sk, "name": "toolu_01.txt",
              "sha256": hashlib.sha256(content.encode()).hexdigest(), "content": content}
        for bad in ({**ok, "name": "../x"}, {**ok, "name": "a/b"}, {**ok, "name": ".hidden"},
                    {**ok, "name": "x%2Fy"}, {**ok, "sha256": "0" * 64}):
            with self.subTest(bad=bad["name"]):
                r = self.c.post(PREFIX + "/blob", content=gz(bad), headers=PRO_DEV)
                self.assertEqual(r.status_code, 400, r.text)
        secret = {**ok, "content": "ghp_" + "A" * 36}
        secret["sha256"] = hashlib.sha256(secret["content"].encode()).hexdigest()
        r = self.c.post(PREFIX + "/blob", content=gz(secret), headers=PRO_DEV)
        self.assertEqual(r.status_code, 422)
        r = self.c.post(PREFIX + "/blob", content=gz(ok), headers=PRO_DEV)
        self.assertEqual(r.json(), {"stored": True})
        self.assertIn(f"sessions/pro-dev/{sk}/tool-results/toolu_01.txt.zst", self.store.objects)
        r = self.c.get(PREFIX + "/archive/tool-results", params={"session_key": sk}, headers=AIR)
        self.assertEqual(r.status_code, 200)
        with tarfile.open(fileobj=io.BytesIO(r.content)) as tar:
            self.assertEqual(tar.getnames(), ["toolu_01.txt"])
            self.assertEqual(tar.extractfile("toolu_01.txt").read().decode(), content)
        # still downloadable after the blob was recorded
        self.assertEqual(self.c.get(PREFIX + "/archive", params={"session_key": sk},
                                    headers=AIR).status_code, 200)
        self.store.objects[f"sessions/pro-dev/{sk}/tool-results/toolu_01.txt.zst"] = arc.compress(b"x")
        r = self.c.get(PREFIX + "/archive/tool-results", params={"session_key": sk}, headers=AIR)
        self.assertEqual((r.status_code, r.json()["error"]), (409, "archive_tampered"))


class Purge(Base):
    def test_delete(self):
        r = self.ingest(segment_body([line("u1", "x")], 0, host="air"), headers=AIR)
        sk = r.json()["session_key"]
        r = self.c.delete(PREFIX + "/session", params={"session_key": sk}, headers=AIR)
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(r.json(), {"deleted_docs": 2, "deleted_objects": 1})
        self.assertEqual(self.store.objects, {})
        self.assertNotIn(sk, FAKE.indices["memory-session"])

    def test_hostless_operator_may_purge_any_host(self):
        sk = self.ingest(segment_body([line("u1", "x")], 0)).json()["session_key"]
        r = self.c.delete(PREFIX + "/session", params={"session_key": sk}, headers=OPERATOR)
        self.assertEqual(r.status_code, 200, r.text)

    def test_hostbound_cannot_purge_other_host(self):
        sk = self.ingest(segment_body([line("u1", "x")], 0)).json()["session_key"]
        r = self.c.delete(PREFIX + "/session", params={"session_key": sk}, headers=AIR)
        self.assertEqual((r.status_code, r.json()["error"]), (403, "host_mismatch"))


class Names(unittest.TestCase):
    SK = "sk_" + "a" * 32

    def test_builder_always_under_sessions(self):
        good = [arc.object_name("pro-dev", self.SK, generation=3, offset=42),
                arc.object_name("air", self.SK, tool_result="toolu_9.txt"),
                arc.object_name("air", self.SK)]
        self.assertEqual(good[0], f"sessions/pro-dev/{self.SK}/g3/000000000042.jsonl.zst")
        self.assertEqual(good[1], f"sessions/air/{self.SK}/tool-results/toolu_9.txt.zst")
        self.assertEqual(good[2], f"sessions/air/{self.SK}/")
        for n in good:
            self.assertTrue(n.startswith("sessions/"))
            self.assertNotIn("..", n.split("/"))

    def test_builder_rejects(self):
        bad = [dict(host="..", session_key=self.SK), dict(host="a/b", session_key=self.SK),
               dict(host="UP", session_key=self.SK), dict(host="h", session_key="../x"),
               dict(host="h", session_key=self.SK, tool_result=".."),
               dict(host="h", session_key=self.SK, tool_result="a%2Fb"),
               dict(host="h", session_key=self.SK, tool_result="../x"),
               dict(host="h", session_key=self.SK, generation=-1, offset=0),
               dict(host="h", session_key=self.SK, generation=0, offset=10 ** 12),
               dict(host="h", session_key=self.SK, generation=True, offset=0)]
        for kw in bad:
            with self.subTest(kw=kw):
                with self.assertRaises(arc.InvalidName):
                    arc.object_name(**kw)

    def test_bounded_decompress(self):
        blob = arc.compress(b"\0" * (6 * 1024 * 1024))
        with self.assertRaises(arc.ArchiveError):
            arc.decompress(blob)
        self.assertEqual(arc.decompress(arc.compress(b"abc")), b"abc")

    def test_backend_from_env(self):
        self.assertIsNone(arc.backend_from_env({}))
        self.assertIsInstance(arc.backend_from_env({"SESSION_ARCHIVE_BACKEND": "gcs",
                                                    "SESSION_ARCHIVE_BUCKET": "b"}), arc.GCSBackend)
        s3 = arc.backend_from_env({"SESSION_ARCHIVE_BACKEND": "s3", "SESSION_ARCHIVE_BUCKET": "b",
                                   "SESSION_ARCHIVE_AWS_ACCESS_KEY_ID": "AKIDEXAMPLE",
                                   "SESSION_ARCHIVE_AWS_SECRET_ACCESS_KEY": "fake",
                                   "SESSION_ARCHIVE_AWS_REGION": "ap-northeast-1"})
        self.assertEqual(s3.host, "b.s3.ap-northeast-1.amazonaws.com")
        for env in ({"SESSION_ARCHIVE_BACKEND": "gcs"}, {"SESSION_ARCHIVE_BACKEND": "ftp",
                                                        "SESSION_ARCHIVE_BUCKET": "b"},
                    {"SESSION_ARCHIVE_BACKEND": "s3", "SESSION_ARCHIVE_BUCKET": "b"}):
            with self.assertRaises(ValueError):
                arc.backend_from_env(env)


class Indices(unittest.TestCase):
    def test_in_process_definitions_equal_committed_json(self):
        for name, (body, schema) in sa.index_definitions().items():
            with open(os.path.join(HERE, "..", "es-indices-v2", f"{name}.json")) as fh:
                committed = json.load(fh)
            self.assertEqual(body, committed, name)
            self.assertEqual(committed["mappings"]["_meta"]["schema"], schema)
            self.assertEqual(committed["mappings"]["dynamic"], "strict")

    def test_setup_script_lists_both(self):
        with open(os.path.join(HERE, "..", "es-indices-v2", "setup_indices_v2.sh")) as fh:
            src = fh.read()
        self.assertIn("memory-session.json", src)
        self.assertIn("memory-session-message.json", src)
        self.assertNotIn('"${SESSION_INDEX}",   "alias"', src)

    def test_ensure_creates_checks_schema_and_tolerates_existing(self):
        FAKE.created.clear()
        asyncio.run(sa.ensure_session_indices())
        self.assertEqual(set(FAKE.created), {"memory-session", "memory-session-message"})
        self.assertEqual(FAKE.created["memory-session"]["settings"]["number_of_replicas"],
                         sa.SESSION_INDEX_REPLICAS)
        asyncio.run(sa.ensure_session_indices())  # already exists: fine
        FAKE.created["memory-session"]["mappings"]["_meta"]["schema"] = "session/0"
        with self.assertRaises(sa.SchemaMismatch):
            asyncio.run(sa.ensure_session_indices())
        FAKE.created.clear()


class Embedding(unittest.TestCase):
    def test_embed_docs_reindexes_with_vector(self):
        FAKE.indices.clear()
        vo = types.ModuleType("voyage")

        async def embed_documents(texts, batch=128):
            return [[0.5] * 4 for _ in texts]

        vo.embed_documents = embed_documents
        sys.modules["voyage"] = vo
        try:
            docs = [{"_id": f"d{i}", "text": "t" * 20000, "embedding_status": "pending",
                     "session_key": "sk"} for i in range(130)]
            asyncio.run(sa._embed_docs(docs))
        finally:
            del sys.modules["voyage"]
        got = FAKE.indices["memory-session-message"]
        self.assertEqual(len(got), 130)
        self.assertTrue(all(s["embedding_status"] == "done" and s["embedding"] == [0.5] * 4
                            for s, _ in got.values()))
        self.assertEqual(docs[0]["embedding_status"], "pending", "input docs are not mutated")


class ServerWiring(unittest.TestCase):
    def test_sessions_mount_precedes_memory_mount(self):
        with open(os.path.join(HERE, "server.py")) as fh:
            src = fh.read()
        a = src.index('Mount("/memory/sessions/v1", app=sessions_app.app)')
        b = src.index('Mount("/memory", app=mcp.streamable_http_app())')
        self.assertLess(a, b)
        self.assertIn("sessions_app.start_background()", src)

    def test_parse_and_redact_versions_exposed(self):
        self.assertEqual(sessions_parse.PARSER_VERSION, "p1")
        self.assertEqual(session_redact.RULESET_VERSION, "r1")


if __name__ == "__main__":
    unittest.main(verbosity=1)
