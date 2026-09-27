#!/usr/bin/env python3
"""Tests for the per-client tool policy (CLIENT_POLICY) of memory-mcp v2.

The policy is the only thing standing between a leaked machine credential and
the whole store: without it every client_credentials token may call every tool.
Each constraint is asserted in BOTH polarities (allowed where it should be,
refused where it should be), so neither an allow-all nor a deny-all version
passes.

Covered here, dependency-free (plain python3, like the other suites):
  - the parser: the production value from memory-mcp-v2.service, other valid
    shapes, and malformed values, which must fail closed;
  - authorize_tool: unlisted client, missing / unknown grant, tool, dataset,
    document length and tags constraints; authorization_code unaffected;
  - es_backend.supersede: a restricted forget by id (or by dataset) cannot
    reach a document outside its datasets;
  - cross-file drift: every policy client is in the proxy's
    ALLOWED_CLIENT_IDS and vice versa, every granted tool exists in server.py,
    and server.py actually builds the gated server.

With --wiring (needs requirements-v2.txt wheels, i.e. a venv python), it also
builds a PolicyFastMCP with the real mcp package and drives tools/call over the
streamable-HTTP app with the proxy's X-Verified-* headers, proving the override
sits on the path every tool call takes. A plain FastMCP is driven the same way
as the negative control. Without --wiring that part is reported as SKIP.

Usage: python3 test_client_policy.py
       /path/to/venv/bin/python test_client_policy.py --wiring
"""

from __future__ import annotations

import ast
import asyncio
import contextlib
import io
import os
import shlex
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
SYSTEMD = os.path.join(HERE, "..", "systemd")
sys.path.insert(0, HERE)

WIRING = "--wiring" in sys.argv[1:]


def unit_env(unit: str, key: str) -> str:
    """Value of `key` from a unit's Environment= lines (systemd quoting)."""
    with open(os.path.join(SYSTEMD, unit), encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line.startswith("Environment="):
                continue
            for assignment in shlex.split(line[len("Environment="):]):
                name, _, value = assignment.partition("=")
                if name == key:
                    return value
    raise SystemExit(f"{unit}: no Environment={key}")


# The production policy, read from the unit that deploys it — so this suite
# fails when the committed value stops meaning what these tests expect.
PRODUCTION_POLICY = unit_env("memory-mcp-v2.service", "CLIENT_POLICY")
os.environ["CLIENT_POLICY"] = PRODUCTION_POLICY
# The proxy shared secret is a separate gate; keep it out of the way here.
os.environ.pop("PROXY_SHARED_SECRET", None)

import identity  # noqa: E402  (after CLIENT_POLICY is set)

# --------------------------------------------------------------------------- #
# es_backend imports httpx / voyage at module load. voyage is stubbed (it needs
# VOYAGE_API_KEY); httpx only when absent, because the --wiring run imports the
# real mcp package, which needs the real httpx.
# --------------------------------------------------------------------------- #
try:
    import httpx  # noqa: F401
except ImportError:
    _httpx = types.ModuleType("httpx")
    _httpx.AsyncClient = lambda *a, **kw: None
    _httpx.Timeout = lambda *a, **kw: None
    _httpx.Response = object
    _httpx.HTTPStatusError = type("HTTPStatusError", (Exception,), {})
    sys.modules["httpx"] = _httpx

os.environ.setdefault("ES_URL", "http://127.0.0.1:9")
os.environ.setdefault("ES_PASSWORD", "stub")

_voyage = types.ModuleType("voyage")


async def _embed(texts):
    return [[0.0] for _ in texts]


_voyage.embed_documents = _embed
sys.modules["voyage"] = _voyage

import es_backend as be  # noqa: E402

PASS = 0
FAIL = 0
SKIP = 0


def check(name, condition, detail=""):
    global PASS, FAIL
    if condition:
        PASS += 1
        print(f"ok   {name}")
    else:
        FAIL += 1
        print(f"FAIL {name} :: {detail}")


def run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


def cc(client_id):
    return {"sub": client_id, "client_id": client_id,
            "grant": identity.GRANT_CLIENT_CREDS, "agent": client_id}


HUMAN = {"sub": "shin1ohno@gmail.com", "client_id": "claude-ai",
         "grant": identity.GRANT_AUTHZ_CODE, "agent": "shin1ohno@gmail.com"}
MIRROR = cc("memory-mirror")
DENIED = (False, identity.POLICY_DENIED_MESSAGE)
ALLOWED = (True, "")


def raises_policy_error(spec):
    try:
        identity.parse_client_policy(spec)
    except identity.PolicyError:
        return True
    return False


# --------------------------------------------------------------------------- #
# 1. parser
# --------------------------------------------------------------------------- #
def test_parser():
    pol = identity.parse_client_policy(PRODUCTION_POLICY)
    check("production policy lists exactly keeper, prober and mirror",
          list(pol) == ["memory-keeper", "monitoring-prober", "memory-mirror"],
          f"got {list(pol)}")
    check("memory-mirror may ingest and forget in file-memory only",
          pol.get("memory-mirror") == {"tools": ("ingest", "forget"),
                                       "datasets": ("file-memory",)},
          f"got {pol.get('memory-mirror')}")
    check("memory-keeper and monitoring-prober are known with no tools",
          all(pol.get(c) == {"tools": (), "datasets": ()}
              for c in ("memory-keeper", "monitoring-prober")),
          f"got {pol}")
    check("module load picked up the unit's policy",
          identity._CLIENT_POLICY == pol and identity._CLIENT_POLICY_ERROR == "",
          f"got {identity._CLIENT_POLICY!r} / {identity._CLIENT_POLICY_ERROR!r}")

    check("empty value is an empty policy", identity.parse_client_policy("") == {})
    check("tools without @datasets grant no dataset",
          identity.parse_client_policy("a=recall") == {"a": {"tools": ("recall",), "datasets": ()}})
    check("several datasets separated by |",
          identity.parse_client_policy("a.b_c-1=ingest@x|y.z")
          == {"a.b_c-1": {"tools": ("ingest",), "datasets": ("x", "y.z")}})

    malformed = [
        "a", "=ingest", "a=;", ";a=", "a=;;b=", "a=b;a=", "a=ingest,ingest",
        "a=ingest@", "a=@x", "a=ingest@x|x", "a=ingest@x@y", "a=ingest@x|",
        "a=,ingest", "a=ingest,", "a= ingest", " a=", "a=ingest ,forget",
        "a=Ingest", "a=in-gest", "a=b=c", "a=ingest@x;", "a=ingest@x y",
        "-a=", "a=ingest@-x", "a=ingest\n", "a=ingest@x\n",
    ]
    bad = [s for s in malformed if not raises_policy_error(s)]
    check(f"{len(malformed)} malformed values are rejected", not bad, f"accepted {bad!r}")

    pol_none, err = identity._load_client_policy("a=ingest@")
    check("a malformed value loads as an invalid (None) policy with a reason",
          pol_none is None and err, f"got {pol_none!r} / {err!r}")
    check("invalid policy: every client_credentials call is denied",
          identity.authorize_tool(MIRROR, "ingest",
                                  {"document": "x", "dataset": "file-memory"},
                                  policy=None) == DENIED)
    check("invalid policy: authorization_code is unaffected",
          identity.authorize_tool(HUMAN, "recall", {"query": "x"}, policy=None) == ALLOWED)
    check("invalid policy: no dataset is allowed",
          identity.allowed_datasets(MIRROR, policy=None) == frozenset())


# --------------------------------------------------------------------------- #
# 2. authorize_tool
# --------------------------------------------------------------------------- #
def test_authorize_tool():
    a = identity.authorize_tool
    ok_ingest = {"document": "note", "dataset": "file-memory", "doc_key": "pro-dev/x/y"}

    check("mirror: ingest into file-memory is allowed", a(MIRROR, "ingest", ok_ingest) == ALLOWED)
    check("mirror: forget by (dataset, doc_key) is allowed",
          a(MIRROR, "forget", {"dataset": "file-memory", "doc_key": "k"}) == ALLOWED)
    check("mirror: forget by id passes the gate (backend scopes it)",
          a(MIRROR, "forget", {"id": "abc"}) == ALLOWED)

    for tool, args in [("recall", {"query": "x"}), ("remember", {"content": "x"}),
                       ("revise", {"id": "a", "content": "x"}), ("get", {"id": "a"}),
                       ("browse", {}), ("memory_stats", {})]:
        check(f"mirror: {tool} is not granted", a(MIRROR, tool, args) == DENIED)

    for client in ("memory-keeper", "monitoring-prober"):
        check(f"{client}: no tool is granted",
              a(cc(client), "recall", {"query": "x"}) == DENIED
              and a(cc(client), "ingest", ok_ingest) == DENIED)

    check("unlisted client is denied", a(cc("someone-else"), "ingest", ok_ingest) == DENIED)
    check("client_credentials with empty client id is denied", a(cc(""), "ingest", ok_ingest) == DENIED)
    for grant in ("", "password", "Client_Credentials", "client_credentials "):
        ident = dict(MIRROR, grant=grant)
        check(f"grant {grant!r} is denied", a(ident, "ingest", ok_ingest) == DENIED)
    check("no identity at all is denied", a({}, "ingest", ok_ingest) == DENIED)

    for ds in ("other", "File-Memory", "file-memory ", ["file-memory"], 1, {"x": 1}):
        check(f"mirror: ingest dataset {ds!r} is denied",
              a(MIRROR, "ingest", dict(ok_ingest, dataset=ds)) == DENIED)
        check(f"mirror: forget dataset {ds!r} is denied",
              a(MIRROR, "forget", {"dataset": ds, "doc_key": "k"}) == DENIED)
    no_ds = dict(ok_ingest)
    del no_ds["dataset"]
    check("mirror: ingest without a dataset is denied", a(MIRROR, "ingest", no_ds) == DENIED)
    check("mirror: forget with an id and a foreign dataset is denied",
          a(MIRROR, "forget", {"id": "abc", "dataset": "other"}) == DENIED)

    limit = identity.RESTRICTED_INGEST_MAX_CHARS
    check("limit is 45000 characters", limit == 45000)
    check("mirror: a document of exactly the limit is allowed",
          a(MIRROR, "ingest", dict(ok_ingest, document="x" * limit)) == ALLOWED)
    check("mirror: one character over the limit is denied",
          a(MIRROR, "ingest", dict(ok_ingest, document="x" * (limit + 1))) == DENIED)
    check("mirror: the limit counts characters, not UTF-8 bytes",
          a(MIRROR, "ingest", dict(ok_ingest, document="あ" * limit)) == ALLOWED)
    for doc in (None, 1, ["x"]):
        check(f"mirror: non-str document {doc!r} is denied",
              a(MIRROR, "ingest", dict(ok_ingest, document=doc)) == DENIED)

    for tags in (["todo"], [], "[]", "null"):
        check(f"mirror: tags={tags!r} is denied",
              a(MIRROR, "ingest", dict(ok_ingest, tags=tags)) == DENIED)
    check("mirror: tags=None (not specified) is allowed",
          a(MIRROR, "ingest", dict(ok_ingest, tags=None)) == ALLOWED)

    check("mirror: arguments None on ingest is denied", a(MIRROR, "ingest", None) == DENIED)
    check("mirror: non-object arguments are denied", a(MIRROR, "forget", ["id"]) == DENIED)
    check("mirror: non-str tool name is denied", a(MIRROR, None, ok_ingest) == DENIED)

    check("human: any tool, dataset and tags are allowed",
          a(HUMAN, "ingest", dict(ok_ingest, dataset="notes", tags=["todo"],
                                  document="x" * (limit + 1))) == ALLOWED
          and a(HUMAN, "recall", {"query": "x"}) == ALLOWED
          and a(HUMAN, "revise", {"id": "a", "content": "x"}) == ALLOWED)

    check("denial reason is the generic policy_denied message",
          identity.POLICY_DENIED_MESSAGE.startswith("policy_denied:"))

    check("allowed_datasets: human is unrestricted (None)", identity.allowed_datasets(HUMAN) is None)
    check("allowed_datasets: mirror gets file-memory",
          identity.allowed_datasets(MIRROR) == frozenset({"file-memory"}))
    check("allowed_datasets: keeper gets nothing",
          identity.allowed_datasets(cc("memory-keeper")) == frozenset())
    check("allowed_datasets: unlisted client gets nothing",
          identity.allowed_datasets(cc("someone-else")) == frozenset())
    check("allowed_datasets: missing grant gets nothing",
          identity.allowed_datasets(dict(MIRROR, grant="")) == frozenset())


# --------------------------------------------------------------------------- #
# 3. startup validation + audit lines
# --------------------------------------------------------------------------- #
def server_tool_names():
    """Names of the @mcp.tool functions in server.py (it cannot be imported
    here: it bootstraps ES at import time)."""
    with open(os.path.join(HERE, "server.py"), encoding="utf-8") as fh:
        tree = ast.parse(fh.read())
    names = []
    for node in tree.body:
        if isinstance(node, ast.AsyncFunctionDef):
            for dec in node.decorator_list:
                target = dec.func if isinstance(dec, ast.Call) else dec
                if (isinstance(target, ast.Attribute) and target.attr == "tool"
                        and isinstance(target.value, ast.Name) and target.value.id == "mcp"):
                    names.append(node.name)
    return names


def capture_stderr(fn, *args):
    buf = io.StringIO()
    with contextlib.redirect_stderr(buf):
        fn(*args)
    return buf.getvalue()


def test_startup_and_audit():
    tools = server_tool_names()
    check("server.py registers the eight contract tools",
          sorted(tools) == sorted(["recall", "remember", "ingest", "revise", "forget",
                                   "get", "browse", "memory_stats"]), f"got {tools}")
    check("every tool the production policy grants exists in server.py",
          identity.unknown_policy_tools(identity._CLIENT_POLICY, tools) == [])
    check("a misspelled tool is reported as unknown",
          identity.unknown_policy_tools(identity.parse_client_policy("a=ingest,forgot@x"), tools)
          == ["forgot"])

    check("startup lines for the production policy",
          identity.policy_lines(identity._CLIENT_POLICY) == [
              "POLICY memory-keeper -> (none) @ (none)",
              "POLICY monitoring-prober -> (none) @ (none)",
              "POLICY memory-mirror -> ingest,forget @ file-memory",
          ], f"got {identity.policy_lines(identity._CLIENT_POLICY)}")
    check("startup line for an invalid policy",
          identity.policy_lines(None, "boom")[0].startswith("AUDIT policy_invalid"))

    saved = (identity._CLIENT_POLICY, identity._CLIENT_POLICY_ERROR)
    try:
        out = capture_stderr(identity.check_client_policy, tools)
        check("check_client_policy keeps a valid policy and logs one POLICY line per client",
              identity._CLIENT_POLICY == saved[0] and out.count("POLICY ") == 3, f"got {out!r}")
        identity._CLIENT_POLICY = identity.parse_client_policy("memory-mirror=ingest,forgot@file-memory")
        out = capture_stderr(identity.check_client_policy, tools)
        check("an unknown tool name invalidates the whole policy (fail-closed)",
              identity._CLIENT_POLICY is None and "AUDIT policy_invalid" in out
              and identity.authorize_tool(MIRROR, "ingest",
                                          {"document": "x", "dataset": "file-memory"}) == DENIED,
              f"got {out!r}")
    finally:
        identity._CLIENT_POLICY, identity._CLIENT_POLICY_ERROR = saved

    out = capture_stderr(identity.audit_policy_deny, "ingest", "memory-mirror", "other")
    check("deny audit line carries tool, client and dataset",
          out == "AUDIT deny tool=ingest client=memory-mirror dataset=other\n", f"got {out!r}")
    out = capture_stderr(identity.audit_policy_deny, "ingest", "memory-mirror",
                         "evil\nAUDIT forged line")
    check("a hostile dataset cannot forge a second log line",
          out.count("\n") == 1 and "dataset=evil?AUDIT?forged?line" in out, f"got {out!r}")
    out = capture_stderr(identity.audit_policy_deny, "x" * 200, None, ["file-memory"])
    check("long values are truncated, non-str values show only their type",
          "tool=" + "x" * 64 + "..." in out and "client=-" in out and "dataset=<list>" in out,
          f"got {out!r}")


# --------------------------------------------------------------------------- #
# 4. es_backend.supersede — restricted forget cannot leave its datasets
# --------------------------------------------------------------------------- #
def test_supersede_scope():
    calls = []

    def meta_for(index, dataset, agent="memory-mirror"):
        async def fake_meta(doc_id):
            src = {"parent_id": "p1", "provenance": {"agent": agent, "source_class": "tool-output"}}
            if dataset is not None:
                src["dataset"] = dataset
            return {"index": index, "source_class": "tool-output", "agent": agent, "source": src}
        return fake_meta

    async def fake_parent(parent_id, sb, now):
        calls.append(("parent", parent_id))
        return 3

    async def fake_mark(index, doc_id, sb, now):
        calls.append(("mark", doc_id))

    async def fake_es_json(method, path, body=None):
        calls.append(("es", path, body))
        return {"updated": 2}

    saved = (be._get_target_meta, be._supersede_parent, be._mark_superseded, be._es_json)
    be._supersede_parent, be._mark_superseded, be._es_json = fake_parent, fake_mark, fake_es_json
    allowed = identity.allowed_datasets(MIRROR)
    grant, agent = identity.GRANT_CLIENT_CREDS, "memory-mirror"

    def attempt(**kw):
        calls.clear()
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            try:
                return run(be.supersede(grant=kw.pop("grant", grant), agent=agent, **kw)), buf.getvalue()
            except be.AuthzError as exc:
                return exc, buf.getvalue()

    try:
        for label, index, dataset in [
            ("another dataset", be.KNOWLEDGE_INDEX, "notes"),
            ("a fact (not knowledge)", be.FACT_INDEX, None),
            ("an episode", be.EPISODE_INDEX, None),
            ("a knowledge doc with no dataset", be.KNOWLEDGE_INDEX, None),
            ("a knowledge doc whose dataset is an array", be.KNOWLEDGE_INDEX, ["file-memory"]),
        ]:
            be._get_target_meta = meta_for(index, dataset)
            res, err = attempt(id="doc1", allowed_datasets=allowed)
            check(f"forget by id: {label} is refused before any write",
                  isinstance(res, be.AuthzError) and str(res) == identity.POLICY_DENIED_MESSAGE
                  and calls == [] and err.startswith("AUDIT deny tool=forget client=memory-mirror"),
                  f"got {res!r} calls={calls} err={err!r}")

        be._get_target_meta = meta_for(be.KNOWLEDGE_INDEX, "file-memory")
        res, err = attempt(id="doc1", allowed_datasets=allowed)
        check("forget by id: own file-memory doc is superseded",
              res == {"superseded_count": 3} and calls == [("parent", "p1")], f"got {res!r} {calls}")

        be._get_target_meta = meta_for(be.KNOWLEDGE_INDEX, "file-memory", agent="shin1ohno@gmail.com")
        res, _ = attempt(id="doc1", allowed_datasets=allowed)
        check("forget by id: in-scope doc written by someone else is still refused (agent rule)",
              isinstance(res, be.AuthzError) and calls == [], f"got {res!r} {calls}")

        be._get_target_meta = meta_for(be.KNOWLEDGE_INDEX, "notes")
        res, _ = attempt(id="doc1", grant=identity.GRANT_AUTHZ_CODE, allowed_datasets=None)
        check("forget by id: unrestricted (authorization_code) reaches any dataset",
              res == {"superseded_count": 3}, f"got {res!r}")

        res, _ = attempt(id="doc1", allowed_datasets=frozenset())
        check("forget by id: an empty allowance refuses everything",
              isinstance(res, be.AuthzError) and calls == [], f"got {res!r}")

        res, err = attempt(dataset="notes", doc_key="k", allowed_datasets=allowed)
        check("forget by (dataset, doc_key): a foreign dataset is refused before any write",
              isinstance(res, be.AuthzError) and calls == [] and "dataset=notes" in err,
              f"got {res!r} {calls}")
        res, _ = attempt(dataset="file-memory", doc_key="k", allowed_datasets=allowed)
        must = calls[0][2]["query"]["bool"]["must"] if calls else []
        check("forget by (dataset, doc_key): own dataset proceeds, still agent-scoped",
              res == {"superseded_count": 2}
              and {"term": {"provenance.agent": "memory-mirror"}} in must
              and {"term": {"dataset": "file-memory"}} in must, f"got {res!r} {calls}")
    finally:
        be._get_target_meta, be._supersede_parent, be._mark_superseded, be._es_json = saved


# --------------------------------------------------------------------------- #
# 5. cross-file drift
# --------------------------------------------------------------------------- #
def test_cross_file():
    proxy_ids = set(unit_env("memory-v2-proxy.service", "ALLOWED_CLIENT_IDS").split(","))
    policy_ids = set(identity.parse_client_policy(PRODUCTION_POLICY))
    check("proxy ALLOWED_CLIENT_IDS and CLIENT_POLICY list the same clients",
          proxy_ids == policy_ids, f"proxy={sorted(proxy_ids)} policy={sorted(policy_ids)}")

    with open(os.path.join(HERE, "server.py"), encoding="utf-8") as fh:
        src = fh.read()
    tree = ast.parse(src)
    check("server.py builds the gated server (mcp = PolicyFastMCP(...))",
          "\nmcp = PolicyFastMCP(" in src)
    check("server.py validates the policy at startup", "\nmcp.check_client_policy()\n" in src)
    forget = next((n for n in tree.body
                   if isinstance(n, ast.AsyncFunctionDef) and n.name == "forget"), None)
    kws = [kw.arg for node in ast.walk(forget) if isinstance(node, ast.Call)
           and isinstance(node.func, ast.Attribute) and node.func.attr == "supersede"
           for kw in node.keywords] if forget else []
    check("server.forget passes allowed_datasets to be.supersede",
          "allowed_datasets" in kws, f"got {kws}")
    with open(os.path.join(HERE, "MANIFEST"), encoding="utf-8") as fh:
        check("policy_mcp.py is deployed (MANIFEST)", "policy_mcp.py" in fh.read().split())


# --------------------------------------------------------------------------- #
# 6. wiring — the override is on the path of every tools/call (real mcp)
# --------------------------------------------------------------------------- #
def build_server(cls, ran):
    srv = cls("policy-wiring-test", stateless_http=True, json_response=True,
              log_level="WARNING")

    @srv.tool()
    async def ingest(document: str, dataset: str, doc_key: str | None = None,
                     tags: list | None = None) -> dict:
        ran.append(("ingest", dataset))
        return {"doc_id": "d1", "chunk_count": 1}

    @srv.tool()
    async def forget(id: str | None = None, dataset: str | None = None,
                     doc_key: str | None = None) -> dict:
        ran.append(("forget", dataset))
        return {"superseded_count": 0}

    @srv.tool()
    async def recall(query: str) -> dict:
        ran.append(("recall", query))
        return {"hits": []}

    return srv


async def drive(srv, requests):
    """POST each (headers, tool, arguments) as a tools/call to the server's own
    streamable-HTTP ASGI app; return the JSON-RPC results."""
    import httpx

    app = srv.streamable_http_app()
    results = []
    async with srv.session_manager.run():
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://127.0.0.1:8010") as client:
            for i, (headers, tool, arguments) in enumerate(requests):
                body = {"jsonrpc": "2.0", "id": i + 1, "method": "tools/call",
                        "params": {"name": tool, "arguments": arguments}}
                resp = await client.post(
                    "/mcp", json=body,
                    headers={"accept": "application/json, text/event-stream", **headers})
                results.append(resp.json().get("result") or resp.json())
    return results


def result_text(result):
    return " ".join(c.get("text", "") for c in (result or {}).get("content", []))


def test_wiring():
    global SKIP
    if not WIRING:
        SKIP += 1
        print("SKIP wiring: run with --wiring under a python that has requirements-v2.txt")
        return
    try:
        from mcp.server.fastmcp import FastMCP
        from policy_mcp import PolicyFastMCP
    except Exception as exc:  # noqa: BLE001 — --wiring demands the real wheels
        check("--wiring: mcp and policy_mcp import", False, repr(exc))
        return

    def hdr(grant, client_id, sub=None):
        return {"x-verified-grant": grant, "x-verified-client-id": client_id,
                "x-verified-sub": sub if sub is not None else client_id}

    mirror = hdr("client_credentials", "memory-mirror")
    human = hdr("authorization_code", "claude-ai", "shin1ohno@gmail.com")
    marker = "SECRET-BODY-MARKER-7f3a"
    requests = [
        (mirror, "recall", {"query": "x"}),
        (mirror, "ingest", {"document": "note", "dataset": "file-memory", "doc_key": "k"}),
        (mirror, "ingest", {"document": marker, "dataset": "other", "doc_key": "k"}),
        (mirror, "ingest", {"document": "note", "dataset": "file-memory", "tags": ["todo"]}),
        (mirror, "forget", {"dataset": "file-memory", "doc_key": "k"}),
        (human, "recall", {"query": "human"}),
        ({}, "recall", {"query": "anonymous"}),
        (hdr("client_credentials", "memory-keeper"), "recall", {"query": "keeper"}),
    ]

    ran = []
    srv = build_server(PolicyFastMCP, ran)
    out = capture_stderr(srv.check_client_policy)
    check("wiring: policy validates against the registered tools",
          identity._CLIENT_POLICY is not None and "POLICY memory-mirror -> ingest,forget @ file-memory" in out,
          f"got {out!r}")

    buf = io.StringIO()
    with contextlib.redirect_stderr(buf):
        res = run(drive(srv, requests))
    audit = buf.getvalue()
    denied = [r.get("isError") is True and result_text(r).startswith("policy_denied:") for r in res]
    succeeded = [r.get("isError") is False for r in res]

    check("wiring: mirror recall is refused over HTTP", denied[0], f"got {res[0]}")
    check("wiring: mirror ingest into file-memory runs", succeeded[1], f"got {res[1]}")
    check("wiring: mirror ingest into another dataset is refused", denied[2], f"got {res[2]}")
    check("wiring: mirror ingest with tags is refused", denied[3], f"got {res[3]}")
    check("wiring: mirror forget in file-memory runs", succeeded[4], f"got {res[4]}")
    check("wiring: authorization_code recall runs", succeeded[5], f"got {res[5]}")
    check("wiring: a call with no identity headers is refused", denied[6], f"got {res[6]}")
    check("wiring: memory-keeper (no tools) is refused", denied[7], f"got {res[7]}")
    check("wiring: refused calls never reach the tool body",
          ran == [("ingest", "file-memory"), ("forget", "file-memory"), ("recall", "human")],
          f"got {ran}")
    check("wiring: every refusal wrote one AUDIT deny line",
          audit.count("AUDIT deny ") == 5, f"got {audit!r}")
    check("wiring: the audit trail never carries the document",
          marker not in audit and "tool=ingest client=memory-mirror dataset=other" in audit,
          f"got {audit!r}")

    # Negative control: the same requests against a plain FastMCP are NOT
    # refused. If they were, the assertions above would prove nothing about the
    # override.
    ran_plain = []
    with contextlib.redirect_stderr(io.StringIO()):
        res_plain = run(drive(build_server(FastMCP, ran_plain), requests[:1]))
    check("wiring control: plain FastMCP runs the mirror recall the gate refuses",
          res_plain[0].get("isError") is False and ran_plain == [("recall", "x")],
          f"got {res_plain} {ran_plain}")

    test_server_module(PolicyFastMCP)


def test_server_module(policy_cls):
    """Import the real server.py (ES bootstrap stubbed out) and check that the
    object it serves is the gated class, with the production policy valid
    against its real tool registrations."""
    stub = types.ModuleType("es_backend")

    async def _no_bootstrap():
        return None

    stub.ensure_indices = _no_bootstrap
    real_be = sys.modules.get("es_backend")
    sys.modules["es_backend"] = stub
    buf = io.StringIO()
    try:
        with contextlib.redirect_stderr(buf):
            import server
    except Exception as exc:  # noqa: BLE001
        check("server.py imports with ES stubbed", False, repr(exc))
        return
    finally:
        sys.modules["es_backend"] = real_be
    out = buf.getvalue()
    check("server.py serves a PolicyFastMCP", isinstance(server.mcp, policy_cls),
          f"got {type(server.mcp)}")
    check("server.py startup logs the production policy as valid",
          out.count("POLICY ") == 3 and "policy_invalid" not in out, f"got {out!r}")
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            run(server.mcp.call_tool("recall", {"query": "x"}))
        refused = False
    except Exception as exc:  # noqa: BLE001
        refused = str(exc).startswith("policy_denied:")
    check("server.py's mcp refuses a call that carries no identity", refused)


test_parser()
test_authorize_tool()
test_startup_and_audit()
test_supersede_scope()
test_cross_file()
test_wiring()

print(f"---- pass={PASS} fail={FAIL} skip={SKIP}")
sys.exit(1 if FAIL else 0)
