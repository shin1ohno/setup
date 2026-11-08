"""Review regressions: stale evidence, decision guards and attempt lifecycle."""
import hashlib
import json
from pathlib import Path
import unittest

import test_envelopes as fixtures


class RevisionTest(unittest.TestCase):
    setUp = fixtures.EnvelopeTest.setUp
    call = fixtures.EnvelopeTest.call
    mutate = fixtures.EnvelopeTest.mutate
    start = fixtures.EnvelopeTest.start
    envelope = fixtures.EnvelopeTest.envelope
    check = fixtures.EnvelopeTest.check
    accept = fixtures.EnvelopeTest.accept

    def task_record(self):
        return self.call("show", self.task)["task"]

    def legacy(self):
        path = self.directory / "task.json"
        task = self.task_record()
        task.pop("contract")
        path.write_text(json.dumps(task))

    def failed_envelope(self):
        return self.envelope(status="failed", criteria=[dict(
            criterion="fixture check", status="fail", evidence=str(self.evidence))])

    def terminal_start(self):
        self.mutate("attempt", "--profile", "dev", "--kind", "codex", "--model", "fixture-model",
                    "--effort", "medium", "--reason", "fixture", "--route", "herdr1")
        self.mutate("bind", "--pane", "old-pane")
        self.mutate("update", "--state", "running", "--note", "running", "--evidence", "live pane")

    def terminal_log(self, session):
        log = self.directory / ("rollout-2026-11-09T00-00-00-" + session + ".jsonl")
        records = [
            {"type": "session_meta", "payload": {"id": session, "cwd": str(self.root)}},
            {"type": "event_msg", "payload": {"type": "item_completed", "item": {
                "type": "UserMessage", "content": [{"type": "text", "text": "read brief"}]}}},
            {"type": "turn_context", "timestamp": "2100-01-01T00:00:00Z",
             "payload": {"model": "fixture-model", "effort": "medium"}},
        ]
        log.write_text("\n".join(json.dumps(r) for r in records) + "\n")
        return log

    def test_f1_rebind_refuses_old_session_and_envelope_bytes(self):
        self.terminal_start()
        old_log = self.terminal_log("11111111-1111-1111-1111-111111111111")
        self.mutate("observe", "--transcript", str(old_log), "--launch-prompt", "read brief")
        old = self.envelope()
        original = old.read_bytes()
        self.mutate("receive", "--file", str(old))
        self.check(0)
        self.mutate("bind", "--pane", "replacement", "--rebind", "--evidence", "new process")
        task = self.task_record()
        self.assertIn(hashlib.sha256(original).hexdigest(),
                      task["attempts"][-1]["invalidated_envelope_sha256"])
        self.assertIn("invalidated", self.mutate("observe", "--transcript", str(old_log),
                      "--launch-prompt", "read brief", ok=False)["error"])
        renamed = self.directory / "renamed.json"
        renamed.write_bytes(original)
        self.assertIn("invalidated", self.mutate("receive", "--file", str(renamed), ok=False)["error"])
        new_log = self.terminal_log("22222222-2222-2222-2222-222222222222")
        self.mutate("observe", "--transcript", str(new_log), "--launch-prompt", "read brief")
        # A replay after a valid replacement observation must clear that pass too.
        self.mutate("observe", "--transcript", str(old_log), "--launch-prompt", "read brief", ok=False)
        self.assertIsNone(self.task_record()["attempts"][-1]["observed_effort"])
        self.mutate("observe", "--transcript", str(new_log), "--launch-prompt", "read brief")
        self.mutate("receive", "--file", str(self.envelope(summary="replacement process evidence")))
        check = self.check(0)["check"]["id"]
        self.assertEqual(self.accept("--check", check)["task"]["state"], "accepted")

    def test_f1_pre_hash_rebind_history_also_refuses_replay(self):
        self.start()
        envelope = self.envelope()
        self.mutate("receive", "--file", str(envelope))
        path = self.directory / "task.json"
        task = self.task_record()
        task["history"].append({"rebind": {"from": "p1", "to": "p2"},
                                 "previous_envelope": task.pop("envelope")})
        task.pop("envelope_sha256")
        path.write_text(json.dumps(task))
        self.assertIn("invalidated", self.mutate("receive", "--file", str(envelope), ok=False)["error"])

    def test_f2_s3_check_before_new_criteria_envelope_cannot_accept(self):
        self.start()
        self.mutate("criteria", "--acceptance", "new check", "--note", "owner answer")
        self.start()
        early = self.check(0)["check"]["id"]
        self.mutate("receive", "--file", str(self.envelope(attempt=2, criteria=[dict(
            criterion="new check", status="pass", evidence=str(self.evidence))])))
        self.accept("--check", early, ok=False)
        current = self.check(0)["check"]
        self.assertEqual(current["envelope_receipt"], self.task_record()["envelope_receipt"])
        self.accept("--check", current["id"])

    def test_f2_s3b_waiver_needs_check_after_failed_replacement(self):
        self.start()
        self.mutate("receive", "--file", str(self.envelope()))
        prior = self.check(0)["check"]
        self.mutate("receive", "--file", str(self.failed_envelope()))
        task = self.task_record()
        self.assertNotEqual(task["envelope_receipt"], prior["envelope_receipt"])
        self.assertEqual(task["history"][-1]["previous_checks"], [prior])
        self.accept("--check", prior["id"], "--waived-by-owner", "owner answer", ok=False)
        check = self.check(0)["check"]["id"]
        self.accept("--check", check, "--waived-by-owner", "owner answer")

    def test_f2_identical_receipt_still_needs_a_later_check(self):
        self.start()
        envelope = self.envelope()
        self.mutate("receive", "--file", str(envelope))
        check = self.check(0)["check"]["id"]
        self.mutate("receive", "--file", str(envelope))
        self.accept("--check", check, ok=False)
        self.accept("--check", self.check(0)["check"]["id"])

    def test_f2_pre_receipt_records_require_rereceive_and_check(self):
        self.start()
        env = self.envelope()
        self.mutate("receive", "--file", str(env))
        check = self.check(0)["check"]["id"]
        path = self.directory / "task.json"
        task = self.task_record()
        task.pop("envelope_receipt")
        task["attempts"][-1]["checks"][-1].pop("envelope_receipt")
        path.write_text(json.dumps(task))
        self.accept("--check", check, ok=False)
        self.mutate("receive", "--file", str(env))
        self.accept("--check", self.check(0)["check"]["id"])

    def test_f4_agent_cannot_hand_bind_before_or_after_refused_observe(self):
        self.mutate("attempt", "--profile", "dev", "--kind", "codex", "--model", "fixture-model",
                    "--effort", "medium", "--reason", "fixture", "--route", "agent")
        self.mutate("bind", "--session", "fixture-worker")
        log = self.directory / "agent-fixture-worker.jsonl"
        for phase in ("unobserved", "refused"):
            if phase == "refused":
                log.write_text("\n".join(json.dumps({"type": "assistant", "message": {
                    "model": "fixture-model"}, "effort": effort}) for effort in ("low", "medium")))
                self.mutate("observe", "--transcript", str(log), ok=False)
            for flag, value in (("--model", "fixture-model"), ("--effort", "medium")):
                with self.subTest(phase=phase, flag=flag):
                    error = self.mutate("bind", "--session", "fixture-worker", flag, value, ok=False)
                    self.assertIn("observe --transcript", error["error"])
                    self.assertIsNone(self.task_record()["attempts"][-1]["observed_effort"])

    def test_f5_criteria_without_attempt_only_changes_text_and_history(self):
        before = self.task_record()
        task = self.mutate("criteria", "--acceptance", "new", "--note", "owner answer")["task"]
        self.assertEqual(task["state"], before["state"])
        self.assertEqual(task["attempts"], [])
        self.assertEqual(task["acceptance"], ["new"])
        self.assertEqual(task["history"][-1]["criteria_change"]["previous"]["acceptance"],
                         ["fixture check"])

    def test_f5_new_attempt_uses_new_envelope_and_stop_marker(self):
        self.start()
        old = self.directory / "envelope-1.json"
        old.write_bytes(self.envelope().read_bytes())
        marker = self.directory / "stop-hook-notified-1"
        marker.write_text("already notified")
        self.mutate("receive", "--file", str(old))
        self.check(0)
        task = self.mutate("criteria", "--acceptance", "new", "--note", "owner answer")["task"]
        self.assertEqual(task["state"], "retry")
        self.assertNotIn("checks", task["attempts"][-1])
        self.assertNotIn("envelope", task)
        self.mutate("update", "--state", "needs-user", "--note", "interrupted controller")
        for state in ("starting", "running", "reviewing"):
            self.assertIn("ended this attempt", self.mutate("update", "--state", state,
                          "--note", "resume", "--evidence", "old worker", ok=False)["error"])
        self.start()
        task = self.task_record()
        number = task["attempts"][-1]["number"]
        self.assertEqual(number, 2)
        fresh = self.directory / f"envelope-{number}.json"
        self.assertFalse(fresh.exists())  # Old envelope cannot wake the new wait.
        self.assertFalse((self.directory / f"stop-hook-notified-{number}").exists())
        self.assertTrue(marker.exists())
        self.assertTrue(old.exists())
        self.mutate("receive", "--file", str(old), ok=False)
        fresh.write_bytes(self.envelope(attempt=number, criteria=[dict(
            criterion="new", status="pass", evidence=str(self.evidence))]).read_bytes())
        self.mutate("receive", "--file", str(fresh))
        self.accept("--check", self.check(0)["check"]["id"])

    def test_f6_m01_waiver_only_applies_to_accepted(self):
        self.start()
        self.mutate("receive", "--file", str(self.failed_envelope()))
        self.mutate("update", "--state", "needs-user", "--note", "review",
                    "--waived-by-owner", "owner answer", ok=False)
        self.assertEqual(self.task_record()["state"], "reviewing")

    def test_f6_m02_legacy_waiver_requires_owner(self):
        self.start()
        self.legacy()
        self.mutate("receive", "--file", str(self.failed_envelope()))
        self.call("update", self.task, "--state", "accepted", "--note", "review",
                  "--evidence", "review", "--waived-by-owner", "owner answer", ok=False)
        self.assertEqual(self.accept("--waived-by-owner", "owner answer")["task"]["state"], "accepted")

    def test_f6_m03_legacy_waiver_requires_an_envelope(self):
        self.start()
        self.legacy()
        self.mutate("update", "--state", "reviewing", "--note", "review", "--evidence", "review")
        self.assertIn("received envelope", self.accept("--waived-by-owner", "owner answer", ok=False)["error"])

    def test_f6_m04_waiver_still_requires_observed_model_and_effort(self):
        self.start()
        self.mutate("receive", "--file", str(self.failed_envelope()))
        check = self.check(0)["check"]["id"]
        path = self.directory / "task.json"
        original = self.task_record()
        for field, bad in (("observed_model", None), ("observed_model", "wrong-model"),
                           ("observed_effort", None), ("observed_effort", "low")):
            with self.subTest(field=field, bad=bad):
                task = json.loads(json.dumps(original))
                task["attempts"][-1][field] = bad
                path.write_text(json.dumps(task))
                self.assertIn("model/effort", self.accept("--check", check,
                              "--waived-by-owner", "owner answer", ok=False)["error"])

    def test_f6_m07_legacy_rebind_requires_owner(self):
        self.terminal_start()
        self.legacy()
        self.call("bind", self.task, "--pane", "new-pane", "--rebind", "--evidence", "move", ok=False)
        self.assertEqual(self.task_record()["attempts"][-1]["pane"], "old-pane")
        self.mutate("bind", "--pane", "new-pane", "--rebind", "--evidence", "move")

    def test_f6_m08_rebind_requires_pane_not_session(self):
        self.start()
        self.assertIn("--pane", self.mutate("bind", "--session", "fixture-worker", "--rebind",
                      "--evidence", "move", ok=False)["error"])

    def test_f6_m20_missing_receive_file_records_refusal(self):
        self.start()
        path = self.directory / "missing-envelope.json"
        error = self.mutate("receive", "--file", str(path), ok=False)["error"]
        record = self.task_record()["history"][-1]
        self.assertIn("Receive refused", record["note"])
        self.assertIn(error, record["note"])
        self.assertEqual(record["evidence"], [str(path)])

    def test_f7_waiver_rejects_passing_or_absent_envelopes(self):
        self.start()
        self.mutate("update", "--state", "reviewing", "--note", "review", "--evidence", "review")
        early = self.check(0)["check"]["id"]
        self.accept("--check", early, "--waived-by-owner", "owner answer", ok=False)
        self.mutate("receive", "--file", str(self.envelope()))
        check = self.check(0)["check"]["id"]
        self.assertIn("does not need", self.accept("--check", check,
                      "--waived-by-owner", "owner answer", ok=False)["error"])
        self.accept("--check", check)

    def test_f9_fresh_pane_scan_includes_original_socket_after_handoffs(self):
        self.terminal_start()
        old_task = self.task
        self.mutate("handoff", "--to", "/second#controller", "--note", "transfer")
        self.call("handoff", old_task, "--owner", "/second#controller", "--to", "/third#controller",
                  "--note", "second transfer")
        task = self.call("new", "--owner", self.owner, "--topic", "fresh", "--cwd", str(self.root),
                         "--scope", "fixture", "--acceptance", "fixture check", "--fresh-worker")["task"]
        self.task = task["id"]
        self.mutate("attempt", "--profile", "dev", "--kind", "codex", "--model", "fixture-model",
                    "--effort", "medium", "--reason", "fixture", "--route", "herdr1")
        self.assertIn("previously bound", self.mutate("bind", "--pane", "old-pane", ok=False)["error"])
        self.mutate("bind", "--pane", "new-pane")

    def test_f10_rebind_rejects_first_bind_and_unchanged_pane(self):
        self.mutate("attempt", "--profile", "dev", "--kind", "codex", "--model", "fixture-model",
                    "--effort", "medium", "--reason", "fixture", "--route", "herdr1")
        for already_bound in (False, True):
            with self.subTest(already_bound=already_bound):
                if already_bound:
                    self.mutate("bind", "--pane", "old-pane")
                self.assertIn("already bound", self.mutate("bind", "--pane", "old-pane",
                              "--rebind", "--evidence", "move", ok=False)["error"])

    def test_f11_refused_receive_invalidates_old_envelope_and_check(self):
        self.start()
        self.mutate("receive", "--file", str(self.envelope()))
        check = self.check(0)["check"]["id"]
        invalid = self.directory / "invalid.json"
        invalid.write_text("{not-json")
        self.mutate("receive", "--file", str(invalid), ok=False)
        task = self.task_record()
        self.assertNotIn("envelope", task)
        self.assertNotIn("envelope_receipt", task)
        self.assertNotIn("checks", task["attempts"][-1])
        self.assertEqual(task["history"][-1]["previous_envelope"]["status"], "done")
        self.accept("--check", check, ok=False)
        self.mutate("receive", "--file", str(self.envelope()))
        self.accept("--check", check, ok=False)
        self.accept("--check", self.check(0)["check"]["id"])


if __name__ == "__main__":
    unittest.main()
