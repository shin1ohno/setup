"""Exercise takeover.py against a private ledger and a fake caller-context helper."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPTS = Path(__file__).parent
OLD = "/socket#w9:p1"
NEW = "/socket#w7:p1"
FAKE_CALLER = """import json, os, sys
if os.environ.get("FAKE_CALLER_FAIL"):
    sys.exit("caller probe failed")
print(os.environ["FAKE_CALLER"])
"""
INJECTOR = """import os, pathlib, sys, time
if sys.argv[1] == "handoff":
    counter = pathlib.Path(os.environ["INJECT_COUNTER"])
    count = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(count))
    if count == int(os.environ["INJECT_AT"]):
        mode = os.environ["INJECT_MODE"]
        if mode == "refuse":
            sys.exit('{"error": "injected refusal"}')
        if mode == "sleep":
            time.sleep(8)
        if mode == "garbage":
            print("not json")
            sys.exit(0)
os.execv(sys.executable, [sys.executable, os.environ["REAL_TASKS"], *sys.argv[1:]])
"""


class TakeoverTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        caller = Path(self.tmp.name) / "caller-context.py"
        caller.write_text(FAKE_CALLER, encoding="utf-8")
        self.state = Path(self.tmp.name) / "state"
        self.env = dict(os.environ, COS_STATE_DIR=str(self.state),
                        COS_CALLER_CONTEXT=str(caller),
                        FAKE_CALLER=json.dumps({"verified": True, "socket": "/socket",
                                                "pane_id": "w7:p1"}))
        self.open = self.new_task("Running work")
        self.ledger("attempt", self.open, "--profile", "dev", "--kind", "codex",
                    "--model", "default", "--reason", "Task fit")
        self.ledger("bind", self.open, "--pane", "w9:p2")
        self.ledger("update", self.open, "--state", "running", "--note", "Started",
                    "--evidence", "Worker observed working")
        self.waiting = self.new_task("Needs the owner")
        self.ledger("update", self.waiting, "--state", "needs-user", "--note", "Budget exhausted",
                    "--evidence", "Attempt limit reached")
        self.unreported = self.accepted_task("Accepted, not yet reported")
        self.reported = self.accepted_task("Accepted and reported")
        self.ledger("reported", self.reported, "--note", "Delivered")

    def ledger(self, *args, ok=True):
        if args[0] == "new":
            args += ("--contract", "legacy",
                     "--linear-waiver", "Owner waived Linear for synthetic fixture")
        result = subprocess.run([sys.executable, str(SCRIPTS / "tasks.py"), *args], env=self.env,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0 if ok else 1, result.stderr)
        return json.loads(result.stdout if ok else result.stderr)

    def new_task(self, topic):
        return self.ledger("new", "--owner", OLD, "--topic", topic, "--cwd", self.tmp.name,
                           "--scope", "Local edits only", "--acceptance", "Actual test passes")["task"]["id"]

    def accepted_task(self, topic):
        task = self.new_task(topic)
        self.ledger("attempt", task, "--profile", "dev", "--kind", "codex", "--model", "default",
                    "--reason", "Task fit")
        self.ledger("bind", task, "--pane", "w9:p3")
        for state in ("running", "reviewing", "accepted"):
            self.ledger("update", task, "--state", state, "--note", "Observed result",
                        "--evidence", "Actual test output")
        return task

    def takeover(self, *extra, ok=True, out=None):
        out = out or str(Path(self.tmp.name) / "out")
        result = subprocess.run([sys.executable, str(SCRIPTS / "takeover.py"), "--from", OLD,
                                 "--to", NEW, "--note", "Owner decision file decision.json",
                                 "--out", out, *extra],
                                env=self.env, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0 if ok else 1, result.stderr)
        return json.loads(result.stdout if ok else result.stderr), Path(out)

    def owners(self):
        return {task: self.ledger("show", task)["task"]["owner"]
                for task in (self.open, self.waiting, self.unreported, self.reported)}

    def test_moves_only_unfinished_tasks_by_default(self):
        report, out = self.takeover()
        self.assertEqual((report["selected"], report["moved"]), (2, 2))
        self.assertEqual(report["states"], {"running": 1, "needs-user": 1})
        self.assertEqual(self.owners(), {self.open: NEW, self.waiting: NEW,
                                         self.unreported: OLD, self.reported: OLD})
        moved = json.loads(Path(report["moved_file"]).read_text())
        self.assertEqual(Path(report["moved_file"]).parent, out)
        running = next(item for item in moved if item["id"] == self.open)
        self.assertEqual((running["pane"], running["attempt"]), ("w9:p2", 1))
        self.assertEqual(running["envelope"], str(self.state.resolve() / self.open / "envelope-1.json"))
        receipts = json.loads(Path(report["receipts_file"]).read_text())
        self.assertEqual({item["id"] for item in receipts["moved"]}, {self.open, self.waiting})
        self.assertEqual((receipts["failure"], receipts["not_moved"]), (None, []))
        history = self.ledger("show", self.open)["task"]["history"][-1]
        self.assertEqual(history["handoff"], {"from": OLD, "to": NEW})
        self.assertIn("decision.json", history["note"])

    def test_report_pending_results_move_only_when_asked(self):
        report, _ = self.takeover("--include-report-pending")
        self.assertEqual(report["moved"], 3)
        self.assertEqual(self.owners()[self.unreported], NEW)
        self.assertEqual(self.owners()[self.reported], OLD)

    def test_dry_run_changes_nothing(self):
        before = self.owners()
        report, out = self.takeover("--dry-run")
        self.assertEqual((report["selected"], report["moved"]), (2, 0))
        self.assertEqual(self.owners(), before)
        self.assertTrue(Path(report["moved_file"]).name.startswith("moved-dry-run-"))
        self.assertIsNone(report["receipts_file"])
        self.assertEqual(list(out.glob("receipts-*.json")), [])

    def test_old_owner_cannot_mutate_after_takeover(self):
        self.takeover()
        refused = "mutation requires this task's verified controller owner"
        stale = self.ledger("update", self.open, "--owner", OLD, "--state", "reviewing",
                            "--note", "Stale controller", "--evidence", "Stale", ok=False)
        self.assertEqual(stale["error"], refused)
        back = self.ledger("handoff", self.open, "--owner", OLD, "--to", OLD,
                           "--note", "Stale controller", ok=False)
        self.assertEqual(back["error"], refused)
        self.ledger("update", self.open, "--owner", NEW, "--state", "reviewing",
                    "--note", "Envelope ready", "--evidence", "Worker wrote its envelope")

    def test_wrong_or_unverified_caller_moves_nothing(self):
        before = self.owners()
        self.env["FAKE_CALLER"] = json.dumps({"verified": True, "socket": "/socket", "pane_id": "w5:p1"})
        error, _ = self.takeover(ok=False)
        self.assertIn("is not --to", error["error"])
        self.env["FAKE_CALLER"] = json.dumps({"verified": False, "socket": "/socket", "pane_id": "w7:p1"})
        self.takeover(ok=False)
        self.env["FAKE_CALLER_FAIL"] = "1"
        self.takeover(ok=False)
        self.assertEqual(self.owners(), before)

    def test_hc_owner_from_caller_context(self):
        hc_owner = "hc:default#t7"
        # The hc helper answers with owner and terminal_id, without socket or pane_id.
        self.env["FAKE_CALLER"] = json.dumps({"verified": True, "owner": hc_owner,
                                              "terminal_id": "t7", "server": "default"})
        result = self.run_takeover("--from", OLD, "--to", hc_owner, "--note", "Owner decision",
                                   "--out", str(Path(self.tmp.name) / "hc"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["moved"], 2)
        self.assertEqual(self.owners()[self.open], hc_owner)
        self.assertEqual(self.owners()[self.waiting], hc_owner)
        wrong = self.run_takeover("--from", hc_owner, "--to", "hc:default#t9", "--note", "Owner decision")
        self.assertEqual(wrong.returncode, 1)
        self.assertIn("is not --to", json.loads(wrong.stderr)["error"])

    def run_takeover(self, *args):
        return subprocess.run([sys.executable, str(SCRIPTS / "takeover.py"), *args],
                              env=self.env, text=True, capture_output=True, timeout=60)

    def test_same_owner_only_as_dry_run(self):
        self.env["FAKE_CALLER"] = json.dumps({"verified": True, "owner": OLD})
        same = ("--from", OLD, "--to", OLD, "--note", "Inventory",
                "--out", str(Path(self.tmp.name) / "same"))
        self.assertEqual(self.run_takeover(*same).returncode, 1)
        dry = self.run_takeover(*same, "--dry-run")
        self.assertEqual(dry.returncode, 0, dry.stderr)
        self.assertEqual(json.loads(dry.stdout)["selected"], 2)

    def injected(self, mode):
        """Copy takeover.py beside a tasks.py wrapper that breaks the second handoff."""
        directory = Path(self.tmp.name) / f"inject-{mode}"
        directory.mkdir()
        (directory / "takeover.py").write_text((SCRIPTS / "takeover.py").read_text())
        (directory / "tasks.py").write_text(INJECTOR)
        self.env.update(REAL_TASKS=str(SCRIPTS / "tasks.py"), INJECT_MODE=mode, INJECT_AT="2",
                        INJECT_COUNTER=str(directory / "count"))
        return directory / "takeover.py"

    def check_partial(self, mode):
        script = self.injected(mode)
        out = Path(self.tmp.name) / f"out-{mode}"
        args = ("--from", OLD, "--to", NEW, "--note", "Owner decision", "--out", str(out),
                "--include-report-pending", "--timeout", "3")
        failed = subprocess.run([sys.executable, str(script), *args], env=self.env, text=True,
                                capture_output=True, timeout=60)
        self.assertEqual(failed.returncode, 1, failed.stderr)
        report = json.loads(json.loads(failed.stderr)["error"])
        order = [item["id"] for item in json.loads(Path(report["moved_file"]).read_text())]
        receipts = json.loads(Path(report["receipts_file"]).read_text())
        self.assertEqual([item["id"] for item in receipts["moved"]], order[:1])
        self.assertEqual(receipts["failure"]["id"], order[1])
        self.assertEqual(receipts["not_moved"], order[1:])
        owners = {task: self.ledger("show", task)["task"]["owner"] for task in order}
        self.assertEqual(owners, {order[0]: NEW, order[1]: OLD, order[2]: OLD})
        return out, receipts

    def test_refusal_mid_run_keeps_receipts_and_stops(self):
        self.check_partial("refuse")

    def test_timeout_mid_run_keeps_receipts_and_stops(self):
        _, receipts = self.check_partial("sleep")
        self.assertIn("timed out", receipts["failure"]["error"])

    def test_unreadable_answer_mid_run_keeps_receipts_and_stops(self):
        _, receipts = self.check_partial("garbage")
        self.assertIn("no JSON", receipts["failure"]["error"])

    def test_rerun_after_failure_moves_the_rest_and_keeps_old_files(self):
        out, first = self.check_partial("refuse")
        before = {path.name: path.read_text() for path in out.glob("receipts-*.json")}
        self.env["INJECT_AT"] = "0"
        rerun = subprocess.run([sys.executable, str(SCRIPTS / "takeover.py"), "--from", OLD, "--to", NEW,
                                "--note", "Owner decision", "--out", str(out),
                                "--include-report-pending"],
                               env=self.env, text=True, capture_output=True, timeout=60)
        self.assertEqual(rerun.returncode, 0, rerun.stderr)
        self.assertEqual(json.loads(rerun.stdout)["moved"], 2)
        after = {path.name: path.read_text() for path in out.glob("receipts-*.json")}
        self.assertEqual(len(after), 2)
        for name, text in before.items():
            self.assertEqual(after[name], text)
        self.assertEqual(self.owners()[self.unreported], NEW)
        self.assertIn(first["failure"]["id"], first["not_moved"])

    def test_blank_note_is_rejected(self):
        result = self.run_takeover("--from", OLD, "--to", NEW, "--note", "  ")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.owners()[self.open], OLD)


if __name__ == "__main__":
    unittest.main()
