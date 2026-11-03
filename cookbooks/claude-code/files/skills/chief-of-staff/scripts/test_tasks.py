"""Exercise ledger guarantees through the same CLI used by both harnesses."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("tasks.py")


class TasksTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = dict(os.environ, COS_STATE_DIR=self.tmp.name + "/state")
        self.task = self.call("new", "--owner", "/socket#w1:p1", "--topic", "A topic",
                              "--cwd", self.tmp.name, "--scope", "Local edits only",
                              "--acceptance", "Actual test passes")["task"]["id"]

    def call(self, *args, ok=True):
        result = subprocess.run([sys.executable, str(SCRIPT), *args], env=self.env,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0 if ok else 1, result.stderr)
        return json.loads(result.stdout if ok else result.stderr)

    def attempt(self, kind="codex"):
        result = self.call("attempt", self.task, "--kind", kind,
                           "--model", "default", "--reason", "Task fit")
        self.call("bind", self.task, "--pane", "w1:p2")
        return result["attempt"]

    def update(self, state, evidence=True, ok=True):
        args = ["update", self.task, "--state", state, "--note", "Observed result"]
        if evidence:
            args += ["--evidence", "Actual test output"]
        return self.call(*args, ok=ok)

    def test_acceptance_requires_review_and_evidence(self):
        self.attempt()
        self.update("running")
        self.update("accepted", ok=False)
        self.update("reviewing")
        self.update("accepted", evidence=False, ok=False)
        result = self.update("accepted")
        self.assertEqual(result["task"]["state"], "accepted")
        self.call("attempt", self.task, "--kind", "claude", "--model", "default",
                  "--reason", "Duplicate", ok=False)
        self.assertEqual(len(self.call("list", "--owner", "/socket#w1:p1")["tasks"]), 1)
        self.call("reported", self.task, "--note", "Verified result delivered")
        self.assertEqual(self.call("list", "--owner", "/socket#w1:p1")["tasks"], [])

    def test_no_duplicate_attempt_during_ambiguous_startup(self):
        self.attempt()
        self.call("attempt", self.task, "--kind", "codex", "--model", "default",
                  "--reason", "Resend after timeout", ok=False)
        task = self.call("show", self.task)["task"]
        self.assertEqual(len(task["attempts"]), 1)
        self.assertEqual(task["attempts"][0]["pane"], "w1:p2")

    def test_budget_and_explicit_extension_preserve_original_criteria(self):
        names = []
        for kind in ("codex", "claude", "codex"):
            names.append(self.attempt(kind)["agent"])
            self.update("reviewing")
            result = self.update("retry")
        self.assertEqual(len(set(names)), 3)
        self.assertEqual(result["task"]["state"], "needs-user")
        self.call("attempt", self.task, "--kind", "claude", "--model", "default",
                  "--reason", "Fourth attempt", ok=False)
        self.call("extend", self.task, "--max-attempts", "4", "--note", "User: try once more")
        self.attempt("claude")
        self.assertEqual(self.call("show", self.task)["task"]["acceptance"],
                         ["Actual test passes"])

    def test_contexts_are_separate_and_reports_survive_resumption(self):
        self.assertEqual(self.call("list", "--owner", "/other-socket#w1:p1")["tasks"], [])
        self.call("reported", self.task, "--note", "Already told user")
        task = self.call("show", self.task)["task"]
        self.assertEqual(task["last_report"]["note"], "Already told user")
        path = Path(self.env["COS_STATE_DIR"]) / self.task / "task.json"
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)

    def test_parallel_reservation_has_one_winner(self):
        argv = [sys.executable, str(SCRIPT), "attempt", self.task, "--kind", "codex",
                "--model", "default", "--reason", "Concurrent reservation"]
        processes = [subprocess.Popen(argv, env=self.env, text=True,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                     for _ in range(2)]
        for process in processes:
            process.communicate(timeout=10)
        self.assertEqual(sorted(process.returncode for process in processes), [0, 1])
        self.assertEqual(len(self.call("show", self.task)["task"]["attempts"]), 1)

    def test_pane_identity_and_execution_cannot_be_guessed(self):
        self.call("attempt", self.task, "--kind", "codex", "--model", "default",
                  "--reason", "Initial choice")
        self.update("running", ok=False)
        self.call("bind", self.task, "--pane", "w1:p2")
        self.call("bind", self.task, "--pane", "w2:p9", ok=False)
        self.call("show", "../../outside", ok=False)
        self.update("needs-user", evidence=False)
        self.update("reviewing")
        self.update("cancelled", evidence=False)
        self.update("reviewing", ok=False)

    def test_interrupted_supervision_resumes_without_new_attempt(self):
        original = self.attempt()
        self.update("running")
        self.update("needs-user", evidence=False)
        self.update("running", evidence=False, ok=False)
        result = self.update("running")
        self.assertEqual(result["task"]["attempts"][0]["agent"], original["agent"])
        self.assertEqual(len(result["task"]["attempts"]), 1)

    def test_correction_keeps_live_agent_name_but_consumes_budget(self):
        original = self.attempt()
        self.update("reviewing")
        self.update("retry")
        result = self.call("attempt", self.task, "--kind", "codex", "--model", "default",
                           "--reason", "Correct the failing criterion", "--reuse-agent")
        self.assertEqual(result["attempt"]["agent"], original["agent"])
        self.assertEqual(result["attempt"]["number"], 2)
        self.call("bind", self.task, "--pane", "w1:p2")
        self.update("reviewing")
        self.update("retry")
        self.call("attempt", self.task, "--kind", "claude", "--model", "default",
                  "--reason", "Mismatched reuse", "--reuse-agent", ok=False)


if __name__ == "__main__":
    unittest.main()
