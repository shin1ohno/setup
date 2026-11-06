"""No worker launch: validate new contracts and old persisted tasks through CLI."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("tasks.py")


class EnvelopeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.owner = "/fixture#controller"
        self.env = dict(os.environ, COS_STATE_DIR=str(self.root / "state"))
        result = self.call("new", "--owner", self.owner, "--topic", "Fixture",
                           "--cwd", str(self.root), "--scope", "fixture only",
                           "--acceptance", "fixture check")
        self.task = result["task"]["id"]
        self.directory = Path(result["directory"])
        self.evidence = self.directory / "check.txt"
        self.evidence.write_text("synthetic test evidence; no real worker")

    def call(self, *args, ok=True):
        result = subprocess.run([sys.executable, str(SCRIPT), *args], env=self.env,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0 if ok else 1, result.stderr)
        return json.loads(result.stdout if ok else result.stderr)

    def mutate(self, command, *args, **kwargs):
        return self.call(command, self.task, "--owner", self.owner, *args, **kwargs)

    def start(self, route="herdr"):
        self.mutate("attempt", "--kind", "codex", "--model", "fixture-model",
                    "--effort", "medium", "--reason", "fixture", "--route", route)
        identity = "--pane" if route == "herdr" else "--session"
        self.mutate("bind", identity, "fixture-worker", "--model", "fixture-model",
                    "--effort", "medium")
        self.mutate("update", "--state", "running", "--note", "fixture",
                    "--evidence", str(self.evidence))

    def envelope(self, **updates):
        value = dict(task_id=self.task, attempt=1, status="done", summary="fixture",
                     artifacts=[str(self.evidence)], open_questions=[],
                     criteria=[dict(criterion="fixture check", status="pass",
                                    evidence=str(self.evidence))])
        value.update(updates)
        path = self.directory / "envelope.json"
        path.write_text(json.dumps(value))
        return path

    def test_passing_envelope_still_needs_independent_review(self):
        self.start()
        self.mutate("receive", "--file", str(self.envelope()))
        self.mutate("update", "--state", "accepted", "--note", "review", ok=False)
        self.mutate("update", "--state", "accepted", "--note", "review",
                    "--evidence", "independent fixture review")

    def test_agent_identity_has_no_invented_pane(self):
        self.start("agent")
        task = self.call("show", self.task)["task"]
        self.assertIsNone(task["attempts"][0]["pane"])
        self.assertEqual(task["attempts"][0]["session"], "fixture-worker")

    def test_requested_selection_is_not_observed_selection(self):
        self.mutate("attempt", "--kind", "codex", "--model", "fixture-model",
                    "--effort", "medium", "--reason", "fixture")
        self.mutate("bind", "--pane", "fixture-worker")
        self.mutate("update", "--state", "running", "--note", "fixture",
                    "--evidence", "fixture")
        self.mutate("receive", "--file", str(self.envelope()))
        self.mutate("update", "--state", "accepted", "--note", "review",
                    "--evidence", "fixture", ok=False)

    def test_wrong_owner_and_implicit_effort_are_rejected(self):
        self.call("attempt", self.task, "--owner", "wrong", "--kind", "codex",
                  "--model", "fixture-model", "--effort", "medium", "--reason", "x", ok=False)
        self.mutate("attempt", "--kind", "codex", "--model", "fixture-model",
                    "--reason", "x", ok=False)

    def test_unverified_stale_oversized_and_escaped_artifacts(self):
        self.start()
        for updates in [dict(attempt=0), dict(attempt=True), dict(summary="x" * 17000),
                        dict(criteria=[dict(criterion="fixture check", status="unverified",
                                            evidence=str(self.evidence))]),
                        dict(artifacts=["/etc/passwd"])]:
            self.mutate("receive", "--file", str(self.envelope(**updates)), ok=False)
        link = self.directory / "outside"
        link.symlink_to("/etc/passwd")
        self.mutate("receive", "--file", str(self.envelope(artifacts=[str(link)])), ok=False)

    def test_retry_invalidates_the_previous_envelope(self):
        self.start()
        self.mutate("receive", "--file", str(self.envelope()))
        self.mutate("update", "--state", "retry", "--note", "fixture", "--evidence", "fixture")
        self.mutate("attempt", "--kind", "codex", "--model", "fixture-model",
                    "--effort", "medium", "--reason", "fixture")
        self.assertNotIn("envelope", self.call("show", self.task)["task"])


if __name__ == "__main__":
    unittest.main()
