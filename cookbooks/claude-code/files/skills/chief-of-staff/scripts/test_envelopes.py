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
        if args[0] == "new":
            args += ("--linear-waiver", "Owner waived Linear for synthetic fixture")
        result = subprocess.run([sys.executable, str(SCRIPT), *args], env=self.env,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0 if ok else 1, result.stderr)
        return json.loads(result.stdout if ok else result.stderr)

    def mutate(self, command, *args, **kwargs):
        return self.call(command, self.task, "--owner", self.owner, *args, **kwargs)

    def start(self, route="agent"):
        self.mutate("attempt", "--profile", "dev", "--kind", "codex", "--model", "fixture-model",
                    "--effort", "medium", "--reason", "fixture", "--route", route)
        identity = "--pane" if route == "herdr" else "--session"
        self.mutate("bind", identity, "fixture-worker")
        log = self.directory / "agent-fixture-worker.jsonl"
        log.write_text(json.dumps({"type": "assistant", "message": {"model": "fixture-model"},
                                   "effort": "medium"}) + "\n")
        self.mutate("observe", "--transcript", str(log))
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

    def check(self, status, **kwargs):
        log = self.directory / ("check-" + str(status) + ".log")
        log.write_text("synthetic controller check output, exit " + str(status))
        return self.mutate("check", "--file", str(log), "--exit-status", str(status),
                           "--note", "fixture check", **kwargs)

    def accept(self, *args, ok=True):
        return self.mutate("update", "--state", "accepted", "--note", "review",
                           "--evidence", "independent fixture review", *args, ok=ok)

    def test_rebind_requires_evidence_and_archives_old_pane(self):
        self.mutate("attempt", "--profile", "dev", "--kind", "codex", "--model", "fixture-model",
                    "--effort", "medium", "--reason", "fixture", "--route", "herdr1")
        self.mutate("bind", "--pane", "old-pane")
        self.mutate("bind", "--pane", "new-pane", ok=False)
        self.mutate("bind", "--pane", "new-pane", "--rebind", ok=False)
        task = self.mutate("bind", "--pane", "new-pane", "--rebind",
                           "--evidence", "old pane exited; new pane observed")["task"]
        self.assertEqual(task["attempts"][-1]["pane"], "new-pane")
        record = next(h for h in task["history"] if "rebind" in h)
        self.assertEqual(record["rebind"], {"from": "old-pane", "to": "new-pane"})
        self.assertEqual(record["evidence"], ["old pane exited; new pane observed"])
        self.assertTrue(record["at"])

    def test_rebind_invalidates_previous_observation_and_review(self):
        self.start()
        self.mutate("receive", "--file", str(self.envelope()))
        self.check(0)
        path = self.directory / "task.json"
        task = json.loads(path.read_text())
        task["attempts"][-1].update(route="herdr1", pane="old-pane")
        path.write_text(json.dumps(task))
        task = self.mutate("bind", "--pane", "replacement", "--rebind",
                           "--evidence", "replacement observed")["task"]
        self.assertNotIn("envelope", task)
        self.assertNotIn("checks", task["attempts"][-1])
        self.assertIsNone(task["attempts"][-1].get("observed_effort"))
        record = next(h for h in task["history"] if "rebind" in h)
        self.assertEqual(record["previous_observation"]["observed_effort"], "medium")
        self.assertTrue(record["previous_checks"])
        self.assertEqual(record["previous_envelope"]["status"], "done")

    def test_fresh_worker_rebind_cannot_reuse_controller_or_historical_pane(self):
        self.mutate("attempt", "--profile", "dev", "--kind", "codex", "--model", "fixture-model",
                    "--effort", "medium", "--reason", "fixture", "--route", "herdr1")
        self.mutate("bind", "--pane", "old-pane")
        path = self.directory / "task.json"
        task = json.loads(path.read_text())
        task["fresh_worker"] = True
        path.write_text(json.dumps(task))
        self.mutate("bind", "--pane", "controller", "--rebind", "--evidence", "move", ok=False)
        self.mutate("bind", "--pane", "new-pane", "--rebind", "--evidence", "move")
        self.mutate("bind", "--pane", "old-pane", "--rebind", "--evidence", "move", ok=False)

    def test_handoff_changes_owner_and_preserves_transfer(self):
        self.call("handoff", self.task, "--owner", "wrong", "--to", "new-owner",
                  "--note", "transfer", ok=False)
        self.call("handoff", self.task, "--to", "new-owner", "--note", "transfer", ok=False)
        task = self.mutate("handoff", "--to", "new-owner", "--note", "controller moved")["task"]
        self.assertEqual(task["owner"], "new-owner")
        record = task["history"][-1]
        self.assertEqual(record["handoff"], {"from": self.owner, "to": "new-owner"})
        self.assertIn("controller moved", record["note"])
        self.assertTrue(record["at"])
        self.mutate("update", "--state", "needs-user", "--note", "old owner", ok=False)
        self.owner = "new-owner"
        self.assertEqual(self.mutate("update", "--state", "needs-user", "--note", "new owner")
                         ["task"]["state"], "needs-user")

    def test_receive_limit_refusal_is_visible_in_show(self):
        self.start()
        path = self.envelope(artifacts=[str(self.evidence)] * 13)
        error = self.mutate("receive", "--file", str(path), ok=False)["error"]
        self.assertIn("12", error)
        self.assertIn("13", error)
        task = self.call("show", self.task)["task"]
        self.assertEqual(task["state"], "running")
        self.assertEqual(len(task["attempts"]), 1)
        self.assertIn(error, task["history"][-1]["note"])
        self.assertEqual(task["history"][-1]["evidence"], [str(path)])
        self.mutate("receive", "--file", str(self.envelope()))

    def test_artifact_directory_refusal_names_path(self):
        self.start()
        error = self.mutate("receive", "--file",
                            str(self.envelope(artifacts=[str(self.directory)])), ok=False)["error"]
        self.assertIn(str(self.directory), error)
        self.assertIn("regular file", error)

    def test_owner_waiver_preserves_failed_criterion_and_requires_checks(self):
        self.start()
        criterion = dict(criterion="fixture check", status="fail", evidence=str(self.evidence))
        self.mutate("receive", "--file", str(self.envelope(status="failed", criteria=[criterion])))
        self.accept(ok=False)
        self.accept("--waived-by-owner", "Owner accepts deviation", ok=False)
        failed = self.check(1)["check"]["id"]
        self.accept("--check", failed, "--waived-by-owner", "Owner accepts deviation", ok=False)
        check = self.check(0)["check"]["id"]
        self.accept("--check", check, ok=False)
        self.call("update", self.task, "--owner", "wrong", "--state", "accepted",
                  "--note", "review", "--evidence", "review", "--check", check,
                  "--waived-by-owner", "Owner accepts deviation", ok=False)
        task = self.accept("--check", check, "--waived-by-owner", "Owner accepts deviation")["task"]
        self.assertEqual(task["state"], "accepted")
        record = task["history"][-1]
        self.assertTrue(record["at"])
        self.assertEqual(record["owner_waiver"]["reason"], "Owner accepts deviation")
        self.assertIn("owner", record["owner_waiver"])
        self.assertEqual(record["owner_waiver"]["owner"], self.owner)
        self.assertEqual(record["owner_waiver"]["acceptance"], ["fixture check"])
        self.assertEqual(record["owner_waiver"]["envelope"]["criteria"], [criterion])

    def test_criteria_change_archives_and_invalidates_prior_pass(self):
        self.start()
        old = self.envelope()
        self.mutate("receive", "--file", str(old))
        check = self.check(0)["check"]["id"]
        self.call("criteria", self.task, "--owner", "wrong", "--acceptance", "new check",
                  "--note", "owner changed scope", ok=False)
        task = self.mutate("criteria", "--acceptance", "new check",
                           "--note", "owner changed scope")["task"]
        self.assertEqual(task["acceptance"], ["new check"])
        self.assertEqual(len(task["attempts"]), 1)
        self.assertNotIn("envelope", task)
        self.assertNotIn("checks", task["attempts"][-1])
        record = task["history"][-1]
        self.assertIn("owner changed scope", record["note"])
        self.assertTrue(record["at"])
        previous = record["criteria_change"]["previous"]
        self.assertEqual(previous["acceptance"], ["fixture check"])
        self.assertEqual(previous["checks"][-1]["id"], check)
        self.assertEqual(previous["envelope"]["criteria"][0]["criterion"], "fixture check")
        self.accept("--check", check, ok=False)
        self.mutate("receive", "--file", str(old), ok=False)
        self.assertEqual(task["state"], "retry")
        self.assertTrue(task["attempts"][-1]["ended_at"])
        self.start()
        self.mutate("receive", "--file", str(old), ok=False)
        fresh = self.envelope(attempt=2, criteria=[dict(criterion="new check", status="pass",
                                                       evidence=str(self.evidence))])
        self.mutate("receive", "--file", str(fresh))
        self.accept("--check", check, ok=False)
        check = self.check(0)["check"]["id"]
        self.assertEqual(self.accept("--check", check)["task"]["state"], "accepted")
        self.mutate("criteria", "--acceptance", "other", "--note", "late", ok=False)

    def test_owner_decision_notes_cannot_be_blank_or_omitted(self):
        for args in [("criteria", "--acceptance", "new"), ("handoff", "--to", "new")]:
            for note in [[], ["--note", "   "]]:
                result = subprocess.run([sys.executable, str(SCRIPT), args[0], self.task,
                                         "--owner", self.owner, *args[1:], *note],
                                        env=self.env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
        result = subprocess.run([sys.executable, str(SCRIPT), "update", self.task,
                                 "--owner", self.owner, "--state", "accepted", "--note", "review",
                                 "--waived-by-owner", "  "], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)

    def test_agent_envelope_round_trip_with_observed_effort(self):
        self.mutate("attempt", "--profile", "dev", "--kind", "codex", "--model", "fixture-model",
                    "--effort", "medium", "--reason", "fixture", "--route", "agent")
        self.mutate("bind", "--session", "fixture-worker")
        self.mutate("update", "--state", "running", "--note", "synchronous result returned",
                    "--evidence", str(self.evidence))
        log = self.directory / "agent-fixture-worker.jsonl"
        log.write_text(json.dumps({"type": "assistant", "message": {"model": "fixture-model"},
                                   "effort": "medium"}) + "\n")
        self.mutate("observe", "--transcript", str(log))
        criterion = dict(criterion="fixture check", status="unverified", evidence=str(self.evidence))
        self.mutate("receive", "--file", str(self.envelope(criteria=[criterion])), ok=False)
        self.mutate("receive", "--file", str(self.envelope()))
        check = self.check(0)["check"]["id"]
        task = self.accept("--check", check)["task"]
        self.assertEqual(task["state"], "accepted")
        self.assertEqual(task["attempts"][-1]["observed_effort"], "medium")
        self.assertIsNone(task["attempts"][-1]["pane"])

    def test_legacy_pre_route_records_support_new_mutations(self):
        self.start()
        path = self.directory / "task.json"
        task = json.loads(path.read_text())
        task.pop("contract")
        task["attempts"][-1].pop("route")
        path.write_text(json.dumps(task))
        self.call("criteria", self.task, "--acceptance", "new", "--note", "change", ok=False)
        self.mutate("criteria", "--acceptance", "new", "--note", "change")
        self.mutate("attempt", "--profile", "dev", "--kind", "codex", "--model", "fixture-model",
                    "--reason", "new criteria")
        self.mutate("bind", "--pane", "legacy-pane")
        self.mutate("bind", "--pane", "replacement", "--rebind", "--evidence", "moved")
        self.mutate("handoff", "--to", "new-owner", "--note", "transfer")
        self.owner = "new-owner"
        self.mutate("update", "--state", "reviewing", "--note", "legacy review", "--evidence", "log")
        self.assertEqual(self.accept()["task"]["state"], "accepted")

    def test_passing_envelope_still_needs_independent_review(self):
        self.start()
        self.mutate("receive", "--file", str(self.envelope()))
        self.mutate("update", "--state", "accepted", "--note", "review", ok=False)
        check = self.check(0)["check"]["id"]
        self.accept("--check", check)

    def test_accepted_is_refused_without_a_recorded_check(self):
        self.start()
        self.mutate("receive", "--file", str(self.envelope()))
        error = self.accept(ok=False)["error"]
        self.assertIn("check recorded for this attempt", error)
        self.accept("--check", "000000000000", ok=False)
        self.assertEqual(self.call("show", self.task)["task"]["state"], "reviewing")

    def test_accepted_is_refused_when_the_latest_check_failed(self):
        self.start()
        self.mutate("receive", "--file", str(self.envelope()))
        passed = self.check(0)["check"]["id"]
        failed = self.check(1)["check"]["id"]
        self.assertIn("latest recorded check failed", self.accept("--check", failed, ok=False)["error"])
        self.accept("--check", passed, ok=False)
        self.assertEqual(self.call("show", self.task)["task"]["state"], "reviewing")

    def test_accepted_is_allowed_with_the_latest_passing_check(self):
        self.start()
        self.mutate("receive", "--file", str(self.envelope()))
        self.check(1)
        record = self.check(0)["check"]
        self.assertTrue(record["passed"])
        self.assertEqual(len(record["sha256"]), 64)
        self.assertIn("pass --check", self.accept(ok=False)["error"])
        result = self.accept("--check", record["id"])
        self.assertEqual(result["task"]["state"], "accepted")

    def test_checks_do_not_carry_over_to_a_new_attempt(self):
        self.start()
        self.mutate("receive", "--file", str(self.envelope()))
        check = self.check(0)["check"]["id"]
        self.mutate("update", "--state", "retry", "--note", "fixture", "--evidence", "fixture")
        self.mutate("attempt", "--profile", "dev", "--kind", "codex", "--model", "fixture-model",
                    "--effort", "medium", "--reason", "fixture", "--route", "agent")
        self.mutate("bind", "--session", "fixture-worker-2")
        log = self.directory / "agent-fixture-worker-2.jsonl"
        log.write_text(json.dumps({"type": "assistant", "message": {"model": "fixture-model"},
                                   "effort": "medium"}) + "\n")
        self.mutate("observe", "--transcript", str(log))
        self.mutate("update", "--state", "running", "--note", "fixture",
                    "--evidence", str(self.evidence))
        self.mutate("receive", "--file", str(self.envelope(attempt=2)))
        self.accept("--check", check, ok=False)

    def test_check_file_must_be_a_contained_regular_file(self):
        self.start()
        for path in ["/etc/passwd", "relative.log", str(self.directory)]:
            self.mutate("check", "--file", path, "--exit-status", "0", "--note", "x", ok=False)
        self.assertNotIn("checks", self.call("show", self.task)["task"]["attempts"][-1])

    def test_bind_values_are_refused_on_envelope_v1_herdr(self):
        self.mutate("attempt", "--profile", "dev", "--kind", "codex", "--model", "fixture-model",
                    "--effort", "medium", "--reason", "fixture")
        for flag, value in (("--model", "fixture-model"), ("--effort", "medium")):
            error = self.mutate("bind", "--pane", "fixture-worker", flag, value, ok=False)
            self.assertIn("observe --transcript", error["error"])
        attempt = self.call("show", self.task)["task"]["attempts"][-1]
        self.assertIsNone(attempt["pane"])
        self.assertIsNone(attempt["observed_model"])
        self.mutate("bind", "--pane", "fixture-worker")
        self.assertEqual(self.call("show", self.task)["task"]["attempts"][-1]["pane"],
                         "fixture-worker")

    def test_agent_route_records_values_from_transcript(self):
        self.start("agent")
        attempt = self.call("show", self.task)["task"]["attempts"][-1]
        self.assertEqual(attempt["observed_model"], "fixture-model")
        self.assertEqual(attempt["observed_effort"], "medium")

    def test_legacy_herdr_still_binds_values_by_hand(self):
        legacy = self.call("new", "--owner", self.owner, "--topic", "Legacy",
                           "--cwd", str(self.root), "--scope", "fixture only",
                           "--acceptance", "fixture check", "--contract", "legacy")["task"]["id"]
        self.call("attempt", legacy, "--owner", self.owner, "--profile", "dev", "--kind", "codex",
                  "--model", "fixture-model", "--effort", "medium", "--reason", "fixture")
        self.call("bind", legacy, "--owner", self.owner, "--pane", "fixture-worker",
                  "--model", "fixture-model", "--effort", "medium")
        attempt = self.call("show", legacy)["task"]["attempts"][-1]
        self.assertEqual(attempt["observed_model"], "fixture-model")
        self.assertEqual(attempt["observed_effort"], "medium")

    def test_agent_identity_has_no_invented_pane(self):
        self.start("agent")
        task = self.call("show", self.task)["task"]
        self.assertIsNone(task["attempts"][0]["pane"])
        self.assertEqual(task["attempts"][0]["session"], "fixture-worker")

    def test_requested_selection_is_not_observed_selection(self):
        self.mutate("attempt", "--profile", "dev", "--kind", "codex", "--model", "fixture-model",
                    "--effort", "medium", "--reason", "fixture")
        self.mutate("bind", "--pane", "fixture-worker")
        self.mutate("update", "--state", "running", "--note", "fixture",
                    "--evidence", "fixture")
        self.mutate("receive", "--file", str(self.envelope()))
        self.mutate("update", "--state", "accepted", "--note", "review",
                    "--evidence", "fixture", ok=False)

    def test_wrong_owner_and_implicit_effort_are_rejected(self):
        self.call("attempt", self.task, "--owner", "wrong", "--profile", "dev", "--kind", "codex",
                  "--model", "fixture-model", "--effort", "medium", "--reason", "x", ok=False)
        self.mutate("attempt", "--profile", "dev", "--kind", "codex", "--model", "fixture-model",
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
        self.mutate("attempt", "--profile", "dev", "--kind", "codex", "--model", "fixture-model",
                    "--effort", "medium", "--reason", "fixture")
        self.assertNotIn("envelope", self.call("show", self.task)["task"])


if __name__ == "__main__":
    unittest.main()
