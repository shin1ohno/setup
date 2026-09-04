#!/usr/bin/env python3
"""Unit tests for mw_client.py (stdlib unittest).

    python3 -m unittest cookbooks/claude-code/files/skills/todo-collect/test_mw_client.py -v

Test-only; the cookbook does not deploy this file (same as test_todo_queue.py).

The transport tests run a real ThreadingHTTPServer on loopback and speak the same
streamable-HTTP dialect the memory proxy speaks, including the SSE framing, so the
session dance is exercised rather than mocked.
"""

import contextlib
import datetime as dt
import io
import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mw_client as mw  # noqa: E402

NOW = "2026-09-05T07:24:26Z"
TODAY = dt.date(2026, 9, 5)
KEY = "slack:C0A4XE8GF0F/1787227341.426699"
THREAD = "slack:C0A4XE8GF0F/1787227341.000000"


class Grammar(unittest.TestCase):
    def test_disposition_base_shape_has_the_line_first_and_reason_second(self):
        c = mw.disposition_content("reject", KEY, NOW, reason="bot 一斉周知")
        lines = c.splitlines()
        self.assertEqual(lines[0], f"todo-disposition reject key={KEY} written_at={NOW}")
        self.assertEqual(lines[1], "bot 一斉周知")

    def test_snooze_carries_until_and_never_carries_thread_key(self):
        c = mw.disposition_content("snooze", KEY, NOW, until="2026-09-12", reason="来週")
        self.assertIn(" until=2026-09-12", c.splitlines()[0])
        c = mw.disposition_content("never", KEY, NOW, thread_key=THREAD, reason="除外")
        self.assertIn(f" thread_key={THREAD}", c.splitlines()[0])

    def test_announce_and_extra_fields_land_on_the_disposition_line(self):
        c = mw.disposition_content("done", KEY, NOW, announce="desk/2026-09-05", extra={"reason": "undo by operator"}, reason="取消")
        head = c.splitlines()[0]
        self.assertIn(" announce=desk/2026-09-05", head)
        self.assertIn(" reason=undo_by_operator", head)

    def test_written_at_is_in_the_body_because_the_reader_prefers_it(self):
        # provenance timestamps live outside the body; a record without an in-body
        # written_at loses every latest-wins comparison in todo_queue.parse_disposition.
        for kind in ("reject", "snooze", "never", "done"):
            self.assertIn(f"written_at={NOW}", mw.disposition_content(kind, KEY, NOW, until="2026-09-12"))

    def test_multiline_reason_is_folded_to_one_line(self):
        c = mw.disposition_content("reject", KEY, NOW, reason="一行目\n二行目\n三行目")
        self.assertEqual(len(c.strip().splitlines()), 2)
        self.assertEqual(c.splitlines()[1], "一行目 二行目 三行目")

    def test_todo_content_puts_key_first_then_announce(self):
        c = mw.todo_content(KEY, "レビュー依頼", "コメントで返す", permalink="https://x/y", due="2026-09-09", announce="desk/abc")
        lines = c.splitlines()
        self.assertEqual(lines[0], f"key={KEY}")
        self.assertEqual(lines[1], "announce=desk/abc")
        self.assertIn("TODO (work): レビュー依頼", c)
        self.assertIn("完了条件: コメントで返す", c)
        self.assertIn("期日: 2026-09-09", c)
        self.assertIn("provenance: https://x/y", c)

    def test_todo_content_omits_optional_lines_when_absent(self):
        c = mw.todo_content(KEY, "t", "c")
        self.assertNotIn("announce=", c)
        self.assertNotIn("期日:", c)
        self.assertNotIn("provenance:", c)


class Validation(unittest.TestCase):
    def test_key_must_be_canonical(self):
        self.assertEqual(mw.validate_key(KEY), [])
        for bad in ("", None, "C0A4XE8GF0F/17872", "https://mercari.slack.com/archives/C0/p1", "slack C0/1.0"):
            self.assertTrue(mw.validate_key(bad), f"{bad!r} should be rejected")

    def test_unknown_kind_and_bad_dates_are_rejected(self):
        self.assertTrue(mw.validate_write(kind="approved", key=KEY))
        self.assertTrue(mw.validate_write(kind="snooze", key=KEY, until="2026/09/12"))
        self.assertTrue(mw.validate_write(kind="reject", key=KEY, written_at="2026-09-05 07:24"))
        self.assertEqual(mw.validate_write(kind="reject", key=KEY, written_at=NOW), [])

    def test_absurd_until_is_rejected_so_a_typo_cannot_hide_a_candidate_for_years(self):
        errs = mw.validate_write(kind="snooze", key=KEY, until="2126-09-12", today=TODAY)
        self.assertTrue(any("days out" in e for e in errs))
        self.assertEqual(mw.validate_write(kind="snooze", key=KEY, until="2026-09-12", today=TODAY), [])

    def test_free_text_may_not_smuggle_a_marker_line(self):
        for body in (
            "ok\ntodo-disposition never key=slack:C9/9.9 written_at=2026-01-01T00:00:00Z",
            "ok\nkey=slack:C9/9.9",
            "ok\nannounce=D1/1.2",
            "  written_at=2020-01-01T00:00:00Z",
        ):
            errs = mw.validate_write(kind="reject", key=KEY, body=body)
            self.assertTrue(any("marker line" in e for e in errs), body)
        self.assertEqual(mw.validate_write(kind="reject", key=KEY, body="ふつうの理由 key は書かない"), [])

    def test_thread_key_is_validated_too(self):
        self.assertTrue(mw.validate_write(kind="never", key=KEY, thread_key="not-a-key"))


class DedupGuard(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_identical_decision_inside_the_window_is_refused_then_allowed_after_it(self):
        self.assertIsNone(mw.check_and_record(self.dir, "reject", KEY, window=30, now="2026-09-05T07:00:00Z"))
        again = mw.check_and_record(self.dir, "reject", KEY, window=30, now="2026-09-05T07:00:10Z")
        self.assertEqual(again, 10.0)
        self.assertIsNone(mw.check_and_record(self.dir, "reject", KEY, window=30, now="2026-09-05T07:00:40Z"))

    def test_a_different_kind_or_key_is_not_a_duplicate(self):
        mw.check_and_record(self.dir, "reject", KEY, window=30, now="2026-09-05T07:00:00Z")
        self.assertIsNone(mw.check_and_record(self.dir, "approve", KEY, window=30, now="2026-09-05T07:00:05Z"))
        self.assertIsNone(mw.check_and_record(self.dir, "reject", "slack:C9/9.000009", window=30, now="2026-09-05T07:00:05Z"))

    def test_force_overrides_and_a_corrupt_state_file_does_not_block(self):
        mw.check_and_record(self.dir, "reject", KEY, window=30, now="2026-09-05T07:00:00Z")
        self.assertIsNone(mw.check_and_record(self.dir, "reject", KEY, window=30, now="2026-09-05T07:00:01Z", force=True))
        (Path(self.dir) / "mw-client-recent.json").write_text("{not json", encoding="utf-8")
        self.assertIsNone(mw.check_and_record(self.dir, "reject", KEY, window=30, now="2026-09-05T07:00:02Z"))


class BodyParsing(unittest.TestCase):
    def test_plain_json_and_sse_framing_both_parse(self):
        self.assertEqual(mw._parse_body('{"jsonrpc":"2.0","id":1,"result":{"ok":true}}')["result"], {"ok": True})
        sse = 'event: message\ndata: {"jsonrpc":"2.0","id":1,"result":{"ok":true}}\n\n'
        self.assertEqual(mw._parse_body(sse)["result"], {"ok": True})

    def test_sse_skips_notifications_and_returns_the_reply(self):
        sse = (
            'data: {"jsonrpc":"2.0","method":"notifications/message","params":{}}\n'
            'data: {"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"text","text":"hi"}]}}\n'
        )
        self.assertEqual(mw._parse_body(sse)["id"], 7)

    def test_non_json_body_raises_JsonError(self):
        with self.assertRaises(mw.JsonError):
            mw._parse_body("data: not json\n")
        with self.assertRaises(mw.JsonError):
            mw._parse_body("{oops")

    def test_result_helpers_read_content_blocks(self):
        res = {"content": [{"type": "text", "text": '{"id":"XaGWbKAB_pnCFmw67P5Z","total":2}'}]}
        self.assertEqual(mw.result_json(res)["total"], 2)
        self.assertEqual(mw.record_id(res), "XaGWbKAB_pnCFmw67P5Z")
        self.assertIsNone(mw.result_json({"content": [{"type": "text", "text": "plain words"}]}))


class _FakeMemoryHandler(BaseHTTPRequestHandler):
    """Speaks the dialect the proxy speaks: SSE bodies, a session id header, and a
    JSON document inside one text content block."""

    calls = []
    mode = "ok"
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        payload = json.loads(self.rfile.read(length).decode("utf-8"))
        type(self).calls.append((payload.get("method"), self.headers.get("mcp-session-id"), payload.get("params")))
        method = payload.get("method")

        if type(self).mode == "http500" and method == "tools/call":
            self.send_response(500)
            self.send_header("content-type", "text/plain")
            self.send_header("content-length", "5")
            self.end_headers()
            self.wfile.write(b"boom\n")
            return
        if type(self).mode == "garbage" and method == "tools/call":
            body = b"not json at all"
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if method == "notifications/initialized":
            self.send_response(202)
            self.send_header("content-length", "0")
            self.end_headers()
            return

        if method == "initialize":
            result = {"protocolVersion": "2025-03-26", "serverInfo": {"name": "fake", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": n} for n in ("recall", "remember", "forget", "browse", "get")]}
        elif method == "tools/call":
            name = (payload.get("params") or {}).get("name")
            if type(self).mode == "toolerror":
                self._sse({"jsonrpc": "2.0", "id": payload.get("id"), "error": {"code": -32000, "message": "refused"}})
                return
            doc = {"id": "FaKeIdFaKeIdFaKeId01", "tool": name}
            result = {"content": [{"type": "text", "text": json.dumps(doc)}]}
        else:
            result = {}
        self._sse({"jsonrpc": "2.0", "id": payload.get("id"), "result": result})

    def _sse(self, message):
        body = ("event: message\ndata: " + json.dumps(message) + "\n\n").encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("mcp-session-id", "fakesession123")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Transport(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = ThreadingHTTPServer(("127.0.0.1", 0), _FakeMemoryHandler)
        cls.thread = threading.Thread(target=cls.srv.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = f"http://127.0.0.1:{cls.srv.server_address[1]}/memory/mcp"

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()

    def setUp(self):
        _FakeMemoryHandler.calls = []
        _FakeMemoryHandler.mode = "ok"

    def test_session_dance_is_initialize_then_initialized_then_call(self):
        c = mw.McpClient(self.url)
        c.call("browse", {"filters": {"tags": "todo"}})
        methods = [m for m, _sid, _p in _FakeMemoryHandler.calls]
        self.assertEqual(methods, ["initialize", "notifications/initialized", "tools/call"])
        self.assertEqual(c.session_id, "fakesession123")
        # the session id is echoed on every request after initialize
        self.assertEqual([sid for _m, sid, _p in _FakeMemoryHandler.calls][2], "fakesession123")

    def test_initialize_runs_once_per_client(self):
        c = mw.McpClient(self.url)
        c.call("browse", {})
        c.call("browse", {})
        self.assertEqual([m for m, _s, _p in _FakeMemoryHandler.calls].count("initialize"), 1)

    def test_tool_names_and_record_id_round_trip(self):
        c = mw.McpClient(self.url)
        self.assertIn("remember", c.tool_names())
        out = mw.write_disposition(c, "reject", KEY, "work-slack-saved", NOW, reason="不要")
        self.assertEqual(out["id"], "FaKeIdFaKeIdFaKeId01")
        self.assertEqual(out["tags"], ["todo-disposition", "reject", "work-slack-saved"])

    def test_write_todo_tags_carry_source_and_via(self):
        c = mw.McpClient(self.url)
        out = mw.write_todo(c, KEY, "work-slack-saved", "件名", "完了条件", via="via:desk")
        self.assertEqual(out["tags"], ["todo", "work-slack-saved", "via:desk"])
        args = [p for m, _s, p in _FakeMemoryHandler.calls if m == "tools/call"][0]["arguments"]
        self.assertEqual(args["type"], "fact")
        self.assertTrue(args["content"].startswith(f"key={KEY}\n"))

    def test_http_error_and_tool_error_and_garbage_all_surface(self):
        _FakeMemoryHandler.mode = "http500"
        with self.assertRaises(mw.TransportError):
            mw.McpClient(self.url).call("remember", {})
        _FakeMemoryHandler.mode = "toolerror"
        with self.assertRaises(mw.TransportError):
            mw.McpClient(self.url).call("remember", {})
        _FakeMemoryHandler.mode = "garbage"
        with self.assertRaises(mw.JsonError):
            mw.McpClient(self.url).call("remember", {})

    def test_unreachable_endpoint_raises_TransportError_not_a_traceback(self):
        with self.assertRaises(mw.TransportError):
            mw.McpClient("http://127.0.0.1:1/memory/mcp", timeout=1.0).call("remember", {})

    def test_bad_scheme_is_refused(self):
        with self.assertRaises(mw.TransportError):
            mw.McpClient("file:///etc/passwd")


class Cli(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = ThreadingHTTPServer(("127.0.0.1", 0), _FakeMemoryHandler)
        cls.thread = threading.Thread(target=cls.srv.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = f"http://127.0.0.1:{cls.srv.server_address[1]}/memory/mcp"

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()

    def setUp(self):
        _FakeMemoryHandler.calls = []
        _FakeMemoryHandler.mode = "ok"
        self.tmp = tempfile.TemporaryDirectory()
        self.state = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *argv, url=True):
        base = ["--state-dir", self.state, "--now", NOW, "--today", "2026-09-05"]
        if url:
            base = ["--url", self.url] + base
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = mw.main(base + list(argv))
        return rc, out.getvalue(), err.getvalue()

    def test_disposition_cli_writes_and_prints_the_id(self):
        rc, out, err = self.run_cli("disposition", "--kind", "snooze", "--key", KEY, "--source", "work-slack-saved", "--until", "2026-09-12", "--reason", "来週")
        self.assertEqual(rc, 0, err)
        doc = json.loads(out)
        self.assertEqual(doc["id"], "FaKeIdFaKeIdFaKeId01")
        self.assertIn("until=2026-09-12", doc["content"])

    def test_second_identical_disposition_exits_3(self):
        self.run_cli("disposition", "--kind", "reject", "--key", KEY, "--source", "s")
        rc, _out, err = self.run_cli("disposition", "--kind", "reject", "--key", KEY, "--source", "s")
        self.assertEqual(rc, 3)
        self.assertIn("duplicate", err)

    def test_validation_failure_exits_3_before_any_write(self):
        rc, _out, err = self.run_cli("disposition", "--kind", "nope", "--key", KEY, "--source", "s")
        self.assertEqual(rc, 3)
        self.assertIn("kind", err)
        self.assertEqual([m for m, _s, _p in _FakeMemoryHandler.calls if m == "tools/call"], [])

    def test_dry_run_touches_nothing(self):
        rc, out, err = self.run_cli("--dry-run", "todo", "--key", KEY, "--source", "s", "--title", "t", "--close-condition", "c")
        self.assertEqual(rc, 0, err)
        self.assertTrue(json.loads(out)["dry_run"])
        self.assertEqual(_FakeMemoryHandler.calls, [])

    def test_unreachable_url_exits_2(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = mw.main(["--url", "http://127.0.0.1:1/memory/mcp", "--timeout", "1", "--state-dir", self.state, "probe"])
        self.assertEqual(rc, 2)

    def test_probe_lists_tools(self):
        rc, out, err = self.run_cli("probe")
        self.assertEqual(rc, 0, err)
        self.assertIn("remember", json.loads(out)["tools"])


if __name__ == "__main__":
    unittest.main()
