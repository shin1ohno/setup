"""Worker task checklist: inbox.py tasks writes <task-dir>/checklist-<attempt>.json."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parent
TASKS = SCRIPTS / "tasks.py"
INBOX = SCRIPTS / "inbox.py"
OWNER = "herdr:evalsock#w1:p1"
ITEMS = [{"text": "Write the failing test", "state": "done"},
         {"text": "Implement", "state": "doing",
          "children": [{"text": "Parser", "state": "done"}, {"text": "Writer", "state": "todo"}]},
         {"text": "Open the draft PR", "state": "todo"}]


class ChecklistTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state = Path(self.tmp.name) / "state"
        self.env = dict(os.environ, COS_STATE_DIR=str(self.state))
        repo = Path(self.tmp.name) / "repo"
        repo.mkdir()
        self.task = self.tasks("new", "--owner", OWNER, "--topic", "Checklist", "--cwd", str(repo),
                               "--scope", "Local", "--acceptance", "Passes",
                               "--linear-waiver", "Synthetic fixture")["task"]["id"]
        self.dir = self.state / self.task
        self.nonce = self.tasks("attempt", self.task, "--owner", OWNER, "--kind", "claude",
                                "--model", "sonnet", "--effort", "low", "--profile", "dev",
                                "--reason", "Synthetic attempt")["attempt"]["nonce"]
        self.file = self.dir / "checklist-1.json"

    def run_script(self, script, *args, stdin=None):
        return subprocess.run([sys.executable, str(script), *args], env=self.env, text=True,
                              capture_output=True, timeout=20, input=stdin)

    def tasks(self, *args):
        result = self.run_script(TASKS, *args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def record(self, items=ITEMS, ok=True, task_dir=None, task_id=None, attempt="1", nonce=None,
               raw=None, stdin=None):
        result = self.run_script(
            INBOX, "tasks", "--task-dir", str(task_dir or self.dir), "--task-id", task_id or self.task,
            "--attempt", attempt, "--nonce", nonce or self.nonce,
            "--items", "-" if stdin is not None else (raw if raw is not None else json.dumps(items)),
            stdin=stdin)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual(len(result.stderr.strip().splitlines()), 1, result.stderr)
        self.assertTrue(result.stderr.startswith("inbox.py: refused: "), result.stderr)
        return result.stderr

    def body(self):
        return json.loads(self.file.read_text(encoding="utf-8"))

    def test_records_two_levels(self):
        self.assertEqual(self.record(), {"recorded": "checklist-1.json", "leaves": 4, "done": 2, "changes": 1})
        body = self.body()
        self.assertEqual(set(body), {"task_id", "attempt", "nonce", "at", "started_at", "items", "changes"})
        self.assertEqual((body["task_id"], body["attempt"], body["nonce"]), (self.task, 1, self.nonce))
        self.assertEqual(body["items"][1]["children"][1], {"text": "Writer", "state": "todo"})
        self.assertEqual(body["changes"], [{"at": body["at"], "plan": 4}])
        self.assertEqual(oct(self.file.stat().st_mode & 0o777), "0o600")

    def test_change_log_records_state_changes(self):
        self.record()
        first = self.body()
        later = json.loads(json.dumps(ITEMS))
        later[1]["children"][1]["state"] = "done"
        later[1]["state"] = "done"
        later[2]["state"] = "failed"
        later.append({"text": "New step", "state": "todo"})
        self.record(later)
        body = self.body()
        self.assertEqual(body["started_at"], first["started_at"])
        moves = [(c.get("parent"), c.get("text"), c.get("from"), c.get("to"), c.get("plan"))
                 for c in body["changes"]]
        self.assertEqual(moves, [
            (None, None, None, None, 4),
            (None, None, None, None, 5),
            (None, "Implement", "doing", "done", None),
            ("Implement", "Writer", "todo", "done", None),
            (None, "Open the draft PR", "todo", "failed", None),
        ], "a new todo item is part of the plan, not a state change")

    def test_change_log_is_capped(self):
        for index in range(210):
            state = "done" if index % 2 else "todo"
            self.record([{"text": "Toggle", "state": state}])
        self.assertEqual(len(self.body()["changes"]), 200)

    def test_reads_items_from_stdin(self):
        self.record(stdin=json.dumps(ITEMS))
        self.assertEqual(len(self.body()["items"]), 3)

    def test_identity_is_validated_like_post(self):
        cases = [
            (dict(task_id="not-a-task"), "invalid task ID"),
            (dict(attempt="0"), "attempt must be an integer from 1 to 999"),
            (dict(attempt="1x"), "attempt must be an integer from 1 to 999"),
            (dict(nonce="abc"), "nonce must be the 16 hex characters from the brief"),
            (dict(nonce="g" * 16), "nonce must be the 16 hex characters from the brief"),
            (dict(task_dir="relative/dir"), "--task-dir must be an absolute path"),
            (dict(task_id="0123456789abcdef"), "--task-dir does not belong to --task-id"),
        ]
        for overrides, reason in cases:
            self.assertIn(reason, self.record(ok=False, **overrides), overrides)
        empty = Path(self.tmp.name) / "fedcba9876543210"
        empty.mkdir()
        self.assertIn("has no ledger task.json",
                      self.record(ok=False, task_dir=empty, task_id="fedcba9876543210"))
        self.assertFalse(self.file.exists())
        self.assertFalse(any(empty.iterdir()))

    def test_post_and_tasks_refuse_the_same_identity(self):
        bad = ("--task-dir", str(self.dir), "--task-id", self.task, "--attempt", "1", "--nonce", "xyz")
        post = self.run_script(INBOX, "post", *bad, "--kind", "note", "--text", "hi")
        tasks = self.run_script(INBOX, "tasks", *bad, "--items", json.dumps(ITEMS))
        self.assertEqual(post.stderr, tasks.stderr)

    def test_item_validation(self):
        cases = [
            ("not json", "--items is not valid JSON"),
            ("{}", "--items must be a non-empty JSON list"),
            ("[]", "--items must be a non-empty JSON list"),
            (json.dumps(["text"]), "item 1 must be an object"),
            (json.dumps([{"text": "a"}]), "item 1 needs text and state"),
            (json.dumps([{"text": "a", "state": "todo", "extra": 1}]), "item 1 needs text and state"),
            (json.dumps([{"text": "a", "state": "started"}]), "item 1 state must be one of"),
            (json.dumps([{"text": 5, "state": "todo"}]), "item 1 text must be a string"),
            (json.dumps([{"text": "\x1b[0m​ ", "state": "todo"}]), "item 1 text is empty after cleaning"),
            (json.dumps([{"text": "é" * 101, "state": "todo"}]), "item 1 text exceeds 200 UTF-8 bytes"),
            (json.dumps([{"text": "a", "state": "todo", "children": {}}]), "item 1 children must be a list"),
            (json.dumps([{"text": "a", "state": "todo", "children": [
                {"text": "b", "state": "todo", "children": [{"text": "c", "state": "todo"}]}]}]),
             "item 1.1 cannot have children: the checklist has two levels"),
            (json.dumps([{"text": str(i), "state": "todo"} for i in range(31)]), "more than 30 top-level items"),
            (json.dumps([{"text": "a", "state": "todo",
                          "children": [{"text": str(i), "state": "todo"} for i in range(16)]}]),
             "item 1 has more than 15 children"),
            (json.dumps([{"text": str(p), "state": "todo",
                          "children": [{"text": str(i), "state": "todo"} for i in range(15)]}
                         for p in range(6)]), "more than 80 leaf items"),
            ("[" + " " * (32 * 1024) + "]", "--items exceeds 32768 bytes"),
        ]
        for raw, reason in cases:
            self.assertIn(reason, self.record(ok=False, raw=raw), raw[:60])
        self.assertFalse(self.file.exists())

    def test_text_is_cleaned_like_post(self):
        self.record([{"text": "a\x1b[31m red\nline `code` ‮flip​", "state": "todo"}])
        self.assertEqual(self.body()["items"][0]["text"], "a red line 'code' flip")

    def test_atomic_replace_never_follows_a_symlink(self):
        outside = Path(self.tmp.name) / "outside.json"
        outside.write_text("keep")
        self.file.symlink_to(outside)
        self.record()
        self.assertEqual(outside.read_text(), "keep")
        self.assertFalse(self.file.is_symlink())
        self.assertEqual(self.body()["changes"], [{"at": self.body()["at"], "plan": 4}],
                         "a planted file is not taken as the previous checklist")
        self.assertEqual([p.name for p in self.dir.iterdir() if p.name.startswith(".checklist-")], [])

    def test_foreign_previous_checklist_is_not_carried(self):
        self.file.write_text(json.dumps({"task_id": self.task, "attempt": 1, "nonce": "0" * 16,
                                         "at": "x", "started_at": "forged", "items": [],
                                         "changes": [{"at": "x", "plan": 99}]}))
        self.record()
        body = self.body()
        self.assertNotEqual(body["started_at"], "forged")
        self.assertEqual([c.get("plan") for c in body["changes"]], [4])

    def test_existing_inbox_and_ledger_output_unchanged(self):
        post = self.run_script(INBOX, "post", "--task-dir", str(self.dir), "--task-id", self.task,
                               "--attempt", "1", "--nonce", self.nonce, "--kind", "note", "--text", "hello")
        self.assertEqual(post.returncode, 0, post.stderr)
        self.assertEqual(set(json.loads(post.stdout)), {"posted", "inbox"})
        before = (self.tasks("inbox", self.task, "--owner", OWNER), self.tasks("show", self.task))
        self.record()
        after = (self.tasks("inbox", self.task, "--owner", OWNER), self.tasks("show", self.task))
        self.assertEqual(before, after, "a checklist changes neither tasks.py inbox nor show")


if __name__ == "__main__":
    unittest.main()
