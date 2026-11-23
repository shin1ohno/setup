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
                              "--acceptance", "Actual test passes", "--contract", "legacy")["task"]["id"]

    def call(self, *args, ok=True):
        if args[0] == "new":
            args += ("--linear-waiver", "Owner waived Linear for synthetic fixture")
        if args[0] == "new" and "--contract" not in args:
            args += ("--contract", "legacy")
        result = subprocess.run([sys.executable, str(SCRIPT), *args], env=self.env,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0 if ok else 1, result.stderr)
        return json.loads(result.stdout if ok else result.stderr)

    def attempt(self, kind="codex"):
        result = self.call("attempt", self.task, "--profile", "dev", "--kind", kind,
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
        self.call("attempt", self.task, "--profile", "dev", "--kind", "claude", "--model", "default",
                  "--reason", "Duplicate", ok=False)
        self.assertEqual(len(self.call("list", "--owner", "/socket#w1:p1")["tasks"]), 1)
        self.call("reported", self.task, "--note", "Verified result delivered")
        self.assertEqual(self.call("list", "--owner", "/socket#w1:p1")["tasks"], [])

    def test_no_duplicate_attempt_during_ambiguous_startup(self):
        self.attempt()
        self.call("attempt", self.task, "--profile", "dev", "--kind", "codex", "--model", "default",
                  "--reason", "Resend after timeout", ok=False)
        task = self.call("show", self.task)["task"]
        self.assertEqual(len(task["attempts"]), 1)
        self.assertEqual(task["attempts"][0]["pane"], "w1:p2")

    def test_explicit_fresh_worker_rejects_controller_old_pane_and_reuse(self):
        self.attempt()
        fresh = self.call("new", "--owner", "/socket#w1:p1", "--topic", "New agent",
                          "--cwd", self.tmp.name, "--scope", "Local", "--acceptance", "Pass",
                          "--fresh-worker")["task"]["id"]
        self.task = fresh
        reserve = ("attempt", fresh, "--profile", "dev", "--kind", "codex", "--model", "default", "--reason", "Fresh")
        self.call(*reserve)
        self.call("bind", fresh, "--pane", "w1:p1", ok=False)
        self.call("bind", fresh, "--pane", "w1:p2", ok=False)
        self.call("bind", fresh, "--pane", "w1:p3")
        self.update("reviewing")
        self.update("retry")
        self.call(*reserve, "--reuse-agent", ok=False)
        self.call(*reserve)
        self.call("bind", fresh, "--pane", "w1:p3", ok=False)
        self.call("bind", fresh, "--pane", "w1:p4")

    def test_budget_and_explicit_extension_preserve_original_criteria(self):
        names = []
        for kind in ("codex", "claude", "codex"):
            names.append(self.attempt(kind)["agent"])
            self.update("reviewing")
            result = self.update("retry")
        self.assertEqual(len(set(names)), 3)
        self.assertEqual(result["task"]["state"], "needs-user")
        self.call("attempt", self.task, "--profile", "dev", "--kind", "claude", "--model", "default",
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
        argv = [sys.executable, str(SCRIPT), "attempt", self.task, "--profile", "dev", "--kind", "codex",
                "--model", "default", "--reason", "Concurrent reservation"]
        processes = [subprocess.Popen(argv, env=self.env, text=True,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                     for _ in range(2)]
        for process in processes:
            process.communicate(timeout=10)
        self.assertEqual(sorted(process.returncode for process in processes), [0, 1])
        self.assertEqual(len(self.call("show", self.task)["task"]["attempts"]), 1)

    def test_pane_identity_and_execution_cannot_be_guessed(self):
        self.call("attempt", self.task, "--profile", "dev", "--kind", "codex", "--model", "default",
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
        result = self.call("attempt", self.task, "--profile", "dev", "--kind", "codex", "--model", "default",
                           "--reason", "Correct the failing criterion", "--reuse-agent")
        self.assertEqual(result["attempt"]["agent"], original["agent"])
        self.assertEqual(result["attempt"]["number"], 2)
        self.call("bind", self.task, "--pane", "w1:p2")
        self.update("reviewing")
        self.update("retry")
        self.call("attempt", self.task, "--profile", "dev", "--kind", "claude", "--model", "default",
                  "--reason", "Mismatched reuse", "--reuse-agent", ok=False)

    def reserve_route(self, route="herdr1", *extra, ok=True):
        return self.call("attempt", self.task, "--profile", "dev", "--kind", "codex",
                         "--model", "default", "--reason", "Route test", "--route", route,
                         *extra, ok=ok)

    def retry_route(self):
        self.call("bind", self.task, "--pane", "w1:p2")
        self.update("reviewing")
        self.update("retry")

    def plan_file(self, name="plan.json", route="herdr1"):
        path = Path(self.tmp.name) / name
        path.write_text(json.dumps({"route": route, "harness": "codex", "launch_ready": True}))
        return str(path)

    def test_default_route_preserves_legacy_callers(self):
        attempt = self.attempt()
        self.assertEqual(attempt["route"], "herdr")
        self.assertIsNone(attempt["plan"])

    def test_reuse_inherits_plan_when_omitted_or_identical(self):
        plan = self.plan_file()
        first = self.reserve_route("herdr1", "--plan", plan)["attempt"]
        self.retry_route()
        second = self.reserve_route("herdr1", "--reuse-agent")["attempt"]
        self.assertEqual(second["plan"], plan)  # Review S1.
        self.assertEqual(second["agent"], first["agent"])
        self.retry_route()
        third = self.reserve_route("herdr1", "--reuse-agent", "--plan", plan)["attempt"]
        self.assertEqual(third["plan"], plan)
        self.assertEqual(self.call("show", self.task)["task"]["attempts"][-1]["plan"], plan)

    def test_reuse_cannot_attach_a_plan_to_default_launch(self):
        self.reserve_route()
        self.retry_route()
        error = self.reserve_route("herdr1", "--reuse-agent", "--plan", self.plan_file(), ok=False)
        self.assertIn("launch plan", error["error"])  # Review S2.
        self.assertEqual(len(self.call("show", self.task)["task"]["attempts"]), 1)
        self.assertIsNone(self.reserve_route("herdr1", "--reuse-agent")["attempt"]["plan"])

    def test_reuse_cannot_replace_plan_or_route(self):
        self.reserve_route("hc", "--plan", self.plan_file(route="hc"))
        self.retry_route()
        error = self.reserve_route("hc", "--reuse-agent", "--plan",
                                   self.plan_file("other.json", "hc"), ok=False)
        self.assertIn("launch plan", error["error"])
        error = self.reserve_route("herdr1", "--reuse-agent", ok=False)
        self.assertIn("route", error["error"])
        self.assertIn("hc", error["error"])
        self.assertIn("herdr1", error["error"])
        self.assertEqual(len(self.call("show", self.task)["task"]["attempts"]), 1)

    def test_plan_requires_existing_absolute_file_and_matching_route(self):
        invalid = ["relative.json", str(Path(self.tmp.name) / "missing.json"), self.tmp.name,
                   self.plan_file("wrong-route.json", "hc")]
        malformed = Path(self.tmp.name) / "malformed.json"
        malformed.write_text("not json")
        invalid.append(str(malformed))
        for path in invalid:
            with self.subTest(path=path):
                self.reserve_route("herdr1", "--plan", path, ok=False)
                self.assertEqual(self.call("show", self.task)["task"]["attempts"], [])

    def test_context_block_before_dispatch_cannot_invent_an_attempt(self):
        self.update("needs-user", evidence=False)
        self.update("starting", ok=False)
        self.assertEqual(self.call("show", self.task)["task"]["attempts"], [])
        self.call("attempt", self.task, "--profile", "dev", "--kind", "codex", "--model", "default",
                  "--reason", "Live controller context restored")
        self.update("needs-user", evidence=False)
        self.update("starting")
        self.call("bind", self.task, "--pane", "w1:p2")

    def test_attempt_requires_an_explicit_profile(self):
        strict = self.call("new", "--owner", "/socket#w1:p1", "--topic", "Profiled",
                           "--cwd", self.tmp.name, "--scope", "Local", "--acceptance", "Pass",
                           "--contract", "envelope-v1")["task"]["id"]
        for task, owner in ((self.task, ()), (strict, ("--owner", "/socket#w1:p1"))):
            argv = [sys.executable, str(SCRIPT), "attempt", task, *owner, "--kind", "claude",
                    "--model", "opus", "--effort", "high", "--reason", "No profile chosen"]
            refused = subprocess.run(argv, env=self.env, text=True, capture_output=True, timeout=10)
            self.assertEqual(refused.returncode, 2, refused.stderr)
            self.assertIn("--profile", refused.stderr)
            self.assertEqual(self.call("show", task)["task"]["attempts"], [])
            self.assertEqual(self.call("show", task)["task"]["state"], "queued")
        result = self.call("attempt", strict, "--owner", "/socket#w1:p1", "--profile", "writing",
                           "--kind", "claude", "--model", "opus", "--effort", "high",
                           "--reason", "Documents row")
        self.assertEqual(result["attempt"]["profile"], "writing")
        self.assertEqual(self.call("show", strict)["task"]["attempts"][-1]["profile"], "writing")

    def test_each_attempt_gets_its_own_nonce(self):
        first = self.attempt()
        self.assertRegex(first["nonce"], r"^[0-9a-f]{16}$")
        shown = self.call("show", self.task)["task"]["attempts"][-1]
        self.assertEqual(shown["nonce"], first["nonce"])
        self.update("needs-user", evidence=False)
        second = self.call("attempt", self.task, "--profile", "dev", "--kind", "codex",
                           "--model", "default", "--reason", "Retry", "--reuse-agent")["attempt"]
        self.assertRegex(second["nonce"], r"^[0-9a-f]{16}$")
        self.assertNotEqual(second["nonce"], first["nonce"])
        attempts = self.call("show", self.task)["task"]["attempts"]
        self.assertEqual([a["nonce"] for a in attempts], [first["nonce"], second["nonce"]])

    def test_pr_records_valid_github_pull_request_urls(self):
        owner = "/socket#w1:p1"
        url = "https://github.com/shin1ohno/setup/pull/1234"
        result = self.call("pr", self.task, "--owner", owner, "--url", url)
        self.assertTrue(result["added"])
        self.assertEqual(result["task"]["pr"], [{"url": url, "repo": "shin1ohno/setup", "number": 1234,
                                                 "added_at": result["task"]["pr"][0]["added_at"]}])
        self.assertEqual(result["task"]["history"][-1]["note"], "Pull request recorded: " + url)
        again = self.call("pr", self.task, "--owner", owner, "--url", url)
        self.assertFalse(again["added"])
        self.assertEqual(len(again["task"]["pr"]), 1)
        for bad in ("http://github.com/o/r/pull/1", "https://github.example.com/o/r/pull/1",
                    "https://github.com/o/r/issues/1", "https://github.com/o/r/pull/0",
                    "https://github.com/o/r/pull/1?x=1", "https://github.com/o/r/pull/1#c",
                    "https://github.com/o/r/pull/1/files", "https://github.com/o/../pull/1",
                    "https://github.com/-o/r/pull/1", "https://user@github.com/o/r/pull/1",
                    "https://github.com/o/r/pull/1\n", "github.com/o/r/pull/1"):
            self.call("pr", self.task, "--owner", owner, "--url", bad, ok=False)
        self.call("pr", self.task, "--owner", "/socket#w9:p9", "--url",
                  "https://github.com/o/r/pull/2", ok=False)
        self.assertEqual([p["url"] for p in self.call("show", self.task)["task"]["pr"]], [url])

    def test_pr_keeps_the_envelope_schema(self):
        self.call("pr", self.task, "--owner", "/socket#w1:p1", "--url",
                  "https://github.com/o/r/pull/9")
        task = self.call("show", self.task)["task"]
        self.assertNotIn("envelope", task)
        self.assertEqual(task["pr"][0]["number"], 9)

    def test_prs_lists_unfinished_tasks_of_this_owner(self):
        owner = "/socket#w1:p1"
        other = self.call("new", "--owner", "/socket#w9:p9", "--topic", "Other", "--cwd", self.tmp.name,
                          "--scope", "Local", "--acceptance", "Pass")["task"]["id"]
        done = self.call("new", "--owner", owner, "--topic", "Done", "--cwd", self.tmp.name,
                         "--scope", "Local", "--acceptance", "Pass")["task"]["id"]
        self.call("pr", self.task, "--owner", owner, "--url", "https://github.com/o/r/pull/1")
        self.call("pr", self.task, "--owner", owner, "--url", "https://github.com/o/s/pull/2")
        self.call("pr", other, "--owner", "/socket#w9:p9", "--url", "https://github.com/o/r/pull/3")
        self.call("pr", done, "--owner", owner, "--url", "https://github.com/o/r/pull/4")
        self.call("update", done, "--owner", owner, "--state", "cancelled", "--note", "Withdrawn")
        listed = self.call("prs", "--owner", owner)["prs"]
        self.assertEqual([(p["task_id"], p["repo"], p["number"]) for p in listed],
                         [(self.task, "o/r", 1), (self.task, "o/s", 2)])
        self.assertEqual({p["state"] for p in listed}, {"queued"})
        self.assertEqual(self.call("prs", "--owner", "/socket#w5:p5")["prs"], [])
        before = (Path(self.tmp.name) / "state" / self.task / "task.json").stat().st_mtime_ns
        self.call("prs", "--owner", owner)
        self.assertEqual((Path(self.tmp.name) / "state" / self.task / "task.json").stat().st_mtime_ns,
                         before)

    def test_journal_appends_one_cleaned_line_per_call(self):
        owner = "/socket#w1:p1"
        first = self.call("journal", "--owner", owner, "--text", "Reported task a1b2 to the owner")
        path = Path(first["journal"])
        self.assertEqual(path.parent, Path(self.tmp.name).resolve() / "state" / "journal")
        self.assertRegex(path.name, r"^\d{4}-\d{2}-\d{2}\.md$")
        self.assertEqual(oct(path.parent.stat().st_mode & 0o777), "0o700")
        self.assertEqual(oct(path.stat().st_mode & 0o777), "0o600")
        self.call("journal", "--owner", owner, "--text", "Owner chose\noption 2 \x1b[1m`now`‮")
        lines = path.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 2)
        self.assertRegex(lines[0], r"^- \d{2}:\d{2} Reported task a1b2 to the owner$")
        self.assertRegex(lines[1], r"^- \d{2}:\d{2} Owner chose option 2 'now'$")
        self.assertEqual(first["line"], lines[0])
        self.call("journal", "--owner", owner, "--text", "x" * 301, ok=False)
        self.call("journal", "--owner", owner, "--text", "​\x07", ok=False)
        self.call("journal", "--owner", owner, "--text", "y" * 300)
        self.assertEqual(len(path.read_text(encoding="utf-8").splitlines()), 3)

    def test_journal_refuses_a_symlinked_directory(self):
        state = Path(self.tmp.name) / "state"
        elsewhere = Path(self.tmp.name) / "elsewhere"
        elsewhere.mkdir()
        (state / "journal").symlink_to(elsewhere)
        self.call("journal", "--owner", "/socket#w1:p1", "--text", "Should not land", ok=False)
        self.assertEqual(list(elsewhere.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
