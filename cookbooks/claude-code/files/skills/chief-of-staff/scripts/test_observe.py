"""No worker launch: observe model/effort from synthetic Agent-tool transcripts."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("tasks.py")
SESSION = "a0123456789abcdef"


class ObserveTest(unittest.TestCase):
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

    def start(self, model="sonnet", effort="low", route="agent"):
        self.mutate("attempt", "--kind", "claude", "--model", model, "--effort", effort,
                    "--reason", "fixture", "--route", route)
        identity = "--session" if route == "agent" else "--pane"
        self.mutate("bind", identity, SESSION)
        self.mutate("update", "--state", "running", "--note", "fixture",
                    "--evidence", str(self.evidence))

    def transcript(self, records, name=None):
        path = self.root / (name or "agent-" + SESSION + ".jsonl")
        lines = [json.dumps(r) for r in records]
        path.write_text("\n".join(lines) + "\n")
        return path

    @staticmethod
    def turn(model="claude-sonnet-5-5", effort="low"):
        record = {"type": "assistant", "message": {"model": model}}
        if effort is not None:
            record["effort"] = effort
        return record

    def receive(self):
        path = self.directory / "envelope.json"
        path.write_text(json.dumps(dict(
            task_id=self.task, attempt=1, status="done", summary="fixture",
            artifacts=[str(self.evidence)], open_questions=[],
            criteria=[dict(criterion="fixture check", status="pass",
                           evidence=str(self.evidence))])))
        self.mutate("receive", "--file", str(path))

    def accept(self, ok=True):
        log = self.directory / "check.log"
        log.write_text("synthetic controller check output")
        check = self.mutate("check", "--file", str(log), "--exit-status", "0",
                            "--note", "fixture check")["check"]["id"]
        return self.mutate("update", "--state", "accepted", "--note", "review",
                           "--evidence", "independent fixture review", "--check", check, ok=ok)

    def test_observed_alias_and_effort_allow_acceptance(self):
        self.start()
        path = self.transcript([{"type": "user"}, self.turn(), self.turn()])
        result = self.mutate("observe", "--transcript", str(path))
        self.assertEqual(result["observed"], {"model": "claude-sonnet-5-5", "effort": "low"})
        attempt = result["task"]["attempts"][-1]
        self.assertEqual(attempt["observed_source"], str(path))
        self.receive()
        self.accept()

    def test_inherited_effort_blocks_acceptance(self):
        self.start(effort="low")
        self.mutate("observe", "--transcript", str(self.transcript([self.turn(effort="medium")])))
        self.receive()
        self.assertIn("model/effort", self.accept(ok=False)["error"])

    def test_other_model_family_blocks_acceptance(self):
        self.start(model="sonnet")
        self.mutate("observe", "--transcript",
                    str(self.transcript([self.turn(model="claude-haiku-5-5")])))
        self.receive()
        self.accept(ok=False)

    def test_unexpected_transcripts_are_refused(self):
        self.start()
        cases = {
            "no assistant turn": [{"type": "user"}],
            "missing effort": [self.turn(effort=None)],
            "mixed pairs": [self.turn(), self.turn(effort="high")],
        }
        for label, records in cases.items():
            with self.subTest(label):
                self.mutate("observe", "--transcript", str(self.transcript(records)), ok=False)
        wrong = self.transcript([self.turn()], name="agent-other.jsonl")
        self.mutate("observe", "--transcript", str(wrong), ok=False)
        task = self.call("show", self.task)["task"]
        self.assertIsNone(task["attempts"][-1]["observed_effort"])

    def test_observe_needs_a_bound_agent_route(self):
        self.start(route="herdr")
        self.mutate("observe", "--transcript", str(self.transcript([self.turn()])), ok=False)

    def test_symlinked_or_special_transcript_is_refused(self):
        self.start()
        real = self.transcript([self.turn()], name="real.jsonl")
        link = self.root / ("agent-" + SESSION + ".jsonl")
        link.symlink_to(real)
        self.mutate("observe", "--transcript", str(link), ok=False)
        link.unlink()
        os.mkfifo(link)
        self.mutate("observe", "--transcript", str(link), ok=False)


if __name__ == "__main__":
    unittest.main()
