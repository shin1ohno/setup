"""Codex native rollout indexing, including retries and segment boundaries."""

import json
import unittest

import sessions_parse as sp

SID = "019aaaaa-1111-7111-8111-111111111111"
CWD = "/work/demo"


def record(kind, payload, ts="2026-10-25T00:00:01Z"):
    return json.dumps({"type": kind, "timestamp": ts, "payload": payload})


def meta(source="vscode"):
    return record("session_meta", {"id": SID, "cwd": CWD, "source": source,
                                   "cli_version": "0.162.1", "git": {"branch": "feature/x"}})


def message(role, text, **extra):
    return record("response_item", dict(type="message", role=role,
                                       content=[{"type": "input_text", "text": text}], **extra))


class CodexParse(unittest.TestCase):
    def parse(self, lines, **kw):
        return sp.parse_lines("sk_" + "a" * 32, "main", lines, 0, host="pro-dev", session_id=SID, **kw)

    def test_conversation_tools_and_noise(self):
        lines = [meta(), message("developer", "injected developer context"),
                 message("user", "# AGENTS.md instructions\nignore"),
                 message("user", "Find the WiFi regression"),
                 message("assistant", "private analysis", channel="analysis"),
                 record("response_item", {"type": "reasoning", "summary": "private reasoning"}),
                 record("event_msg", {"type": "agent_message", "message": "duplicate event text"}),
                 message("assistant", "I found the cause"),
                 record("response_item", {"type": "function_call", "name": "exec_command",
                                          "arguments": '{"cmd":"git status"}', "call_id": "c1"}),
                 record("response_item", {"type": "function_call_output", "call_id": "c1",
                                          "output": "H" * 2000 + "middle" + "T" * 2000})]
        parsed = self.parse(lines)
        docs = parsed["docs"]
        self.assertEqual(len(docs), 4)
        self.assertEqual([d["text"] for d in docs if d.get("text")],
                         ["Find the WiFi regression", "I found the cause"])
        self.assertTrue(all(d["interactive"] for d in docs))
        self.assertTrue(all(d["cwd"] == CWD for d in docs))
        self.assertIn("git status", docs[2]["tool_text"])
        self.assertNotIn("middle", docs[3]["tool_text"])
        self.assertTrue(docs[3]["tool_text"].endswith("T" * 512))
        session = sp.merge_session(None, parsed["delta"], project_dir="codex-" + sp.encode_cwd(CWD))
        self.assertEqual(session["entrypoint"], "codex-vscode")
        self.assertEqual(session["title"], "Find the WiFi regression")
        self.assertEqual(session["git_branch"], "feature/x")
        self.assertTrue(session["resume_cwd_verified"])
        self.assertEqual(self.parse(lines)["docs"], docs)

    def test_later_segment_retains_source_and_cwd(self):
        parsed = self.parse([message("assistant", "later segment")],
                            known_entrypoint="codex-cli", known_cwd=CWD)
        self.assertEqual(parsed["docs"][0]["cwd"], CWD)
        self.assertEqual(parsed["docs"][0]["text"], "later segment")
        self.assertTrue(parsed["docs"][0]["interactive"])

    def test_sources_and_tombstones(self):
        for source, interactive in (("exec", False), ({"subAgent": {}}, False),
                                    ("appServer", True), ("cli", True)):
            parsed = self.parse([meta(source), message("user", "hello"),
                                 json.dumps({"type": "session-search-tombstone", "reason": "unmasked_secret"})])
            self.assertEqual(parsed["docs"][0]["interactive"], interactive)
            self.assertEqual(parsed["delta"]["tombstones"], 1)

    def test_masked_header_does_not_hide_later_messages(self):
        parsed = self.parse([json.dumps({"type": "session-search-tombstone"}),
                             message("user", "still searchable", id=123)], source="codex")
        self.assertEqual(parsed["docs"][0]["text"], "still searchable")
        self.assertEqual(parsed["delta"]["tombstones"], 1)
        self.assertEqual(parsed["delta"]["entrypoint"], "codex-unknown")


if __name__ == "__main__":
    unittest.main()
