#!/usr/bin/env python3
"""Hermetic tests for the memory (Streamable HTTP) leg of probe.py.

    python3 -B cookbooks/mcp-probe/files/test_probe.py

Stdlib only, like probe.py. A local stub stands in for nginx + auth-proxy +
memory-mcp and keeps the two rules the real stack has (ai-memory 33b362e,
mcp 1.30.0, starlette 1.10.0):

  * `/memory/mcp/` is redirected (307) to `/memory/mcp`; through auth-proxy
    that redirect becomes a 502, so the stub answers 502 like production.
  * the server is stateful: initialize returns Mcp-Session-Id and every
    later message without it is answered 400 "Missing session ID".

Only get_token() is replaced; no Hydra call and no secret are involved.
"""

from __future__ import annotations

import importlib.util
import json
import os
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("probe", os.path.join(HERE, "probe.py"))
probe = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(probe)

SESSION = "0123456789abcdef0123456789abcdef"
MEMORY = [s for s in probe.SERVERS if s[0] == "memory"][0]


class Stub(BaseHTTPRequestHandler):
    seen: list = []
    tools_error = False

    def log_message(self, *args):
        pass

    def _send(self, status, body=b"", headers=None):
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _sse(self, msg, headers=None):
        body = f"event: message\ndata: {json.dumps(msg)}\n\n".encode()
        self._send(200, body, {"Content-Type": "text/event-stream", **(headers or {})})

    def _record(self, payload):
        Stub.seen.append((self.command, self.path, self.headers.get("Mcp-Session-Id"), payload))

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        payload = json.loads(raw) if raw else None
        self._record(payload)
        if self.path == "/memory/mcp/":
            # Starlette 307 -> auth-proxy follows it to https://127.0.0.1 -> 502.
            return self._send(502, b'{"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"upstream_error"}}')
        if self.path != "/memory/mcp":
            return self._send(404)
        if payload.get("method") == "initialize":
            return self._sse({"jsonrpc": "2.0", "id": payload["id"], "result": {"protocolVersion": "2024-11-05"}},
                             {"mcp-session-id": SESSION})
        if self.headers.get("Mcp-Session-Id") != SESSION:
            return self._send(400, b'{"jsonrpc":"2.0","id":"server-error","error":{"code":-32600,"message":"Bad Request: Missing session ID"}}')
        if "id" not in payload:
            return self._send(202, headers={"Content-Type": "application/json"})
        if Stub.tools_error:
            return self._sse({"jsonrpc": "2.0", "id": payload["id"], "error": {"code": -32603, "message": "boom"}})
        return self._sse({"jsonrpc": "2.0", "id": payload["id"], "result": {"tools": []}})

    def do_DELETE(self):
        self._record(None)
        ok = self.path == "/memory/mcp" and self.headers.get("Mcp-Session-Id") == SESSION
        self._send(200 if ok else 400)


class MemoryProbe(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = ThreadingHTTPServer(("127.0.0.1", 0), Stub)
        cls.base = f"http://127.0.0.1:{cls.srv.server_address[1]}"
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        probe.get_token = lambda *a, **k: ("stub-token", 0.0, None)

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()

    def setUp(self):
        Stub.seen = []
        Stub.tools_error = False

    def run_probe(self):
        lines = probe.probe_one(MEMORY, "http://unused", "monitoring-prober", "unused", self.base)
        return {line.rsplit(" ", 1)[0]: line.rsplit(" ", 1)[1] for line in lines}

    def test_end_to_end_success(self):
        m = self.run_probe()
        self.assertEqual(m['mcp_probe_phase_success{server="memory",phase="initialize"}'], "1")
        self.assertEqual(m['mcp_probe_phase_success{server="memory",phase="tools_list"}'], "1")
        self.assertEqual(m['mcp_probe_e2e_success{server="memory"}'], "1")

    def test_path_has_no_trailing_slash(self):
        self.run_probe()
        self.assertTrue(Stub.seen)
        self.assertEqual({path for _, path, _, _ in Stub.seen}, {"/memory/mcp"})

    def test_session_carried_and_closed(self):
        self.run_probe()
        calls = [(cmd, (p or {}).get("method"), sid) for cmd, _, sid, p in Stub.seen]
        self.assertEqual(calls, [
            ("POST", "initialize", None),
            ("POST", "notifications/initialized", SESSION),
            ("POST", "tools/list", SESSION),
            ("DELETE", None, SESSION),
        ])

    def test_jsonrpc_error_in_200_fails_tools_list(self):
        Stub.tools_error = True
        m = self.run_probe()
        self.assertEqual(m['mcp_probe_phase_success{server="memory",phase="tools_list"}'], "0")
        self.assertEqual(m['mcp_probe_e2e_success{server="memory"}'], "0")
        self.assertEqual(Stub.seen[-1][0], "DELETE")

    def test_initialize_failure_stops_before_tools(self):
        m = probe.probe_one(("memory", "memory", "/memory/mcp/", "http"),
                            "http://unused", "monitoring-prober", "unused", self.base)
        m = {line.rsplit(" ", 1)[0]: line.rsplit(" ", 1)[1] for line in m}
        self.assertEqual(m['mcp_probe_phase_success{server="memory",phase="initialize"}'], "0")
        self.assertEqual(m['mcp_probe_e2e_success{server="memory"}'], "0")
        self.assertEqual(len(Stub.seen), 1)


if __name__ == "__main__":
    unittest.main()
