"""No worker launch: observe model/effort from synthetic herdr-route session logs.

Fixtures carry only the fields the parser reads (type, timestamp, session and
cwd identity, model, effort), copied in shape from real Claude Code session
logs and Codex 0.167 rollouts; no message text."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("tasks.py")
CLAUDE_SESSION = "ff08475d-0627-4047-89fd-86a87f58e8dc"
CODEX_SESSION = "01a1b1ef-6431-71a2-bb8f-66dc17785e68"
BEFORE = "2000-01-01T00:00:00.000Z"
AFTER = "2100-01-01T00:00:00.000Z"
PROMPT = "Read /fixture/brief.md and do the task it describes."


class HerdrObserveTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.owner = "hc:default#t1"
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

    def start(self, kind="claude", model="sonnet", effort="medium", bind=True, route="herdr", plan=None):
        self.mutate("attempt", "--profile", "dev", "--kind", kind, "--model", model, "--effort", effort,
                    "--reason", "fixture", "--route", route,
                    *(["--plan", str(plan)] if plan else []))
        if bind:
            self.mutate("bind", "--pane", "t2")
            self.mutate("update", "--state", "running", "--note", "fixture",
                        "--evidence", str(self.evidence))

    def log(self, name, records):
        path = self.root / name
        path.write_text("\n".join(json.dumps(r) for r in records) + "\n")
        return path

    # Claude Code session log: ~/.claude/projects/<slug>/<session>.jsonl
    def claude_log(self, records, name=CLAUDE_SESSION + ".jsonl", cwd=None, prompt=PROMPT):
        meta = {"type": "user", "isMeta": True, "sessionId": CLAUDE_SESSION,
                "timestamp": AFTER, "message": {"content": "injected context"}}
        start = {"type": "user", "sessionId": CLAUDE_SESSION, "timestamp": AFTER,
                 "cwd": cwd or str(self.root), "message": {"content": prompt}}
        return self.log(name, [{"type": "permission-mode", "sessionId": CLAUDE_SESSION},
                               meta, start, *records])

    @staticmethod
    def turn(model="claude-sonnet-5-5", effort="medium", at=AFTER, **extra):
        record = {"type": "assistant", "sessionId": CLAUDE_SESSION, "timestamp": at,
                  "message": {"model": model}, **extra}
        if effort is not None:
            record["effort"] = effort
        return record

    # Codex rollout: ~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<session>.jsonl
    def codex_log(self, records, session=CODEX_SESSION, cwd=None, meta=True, prompt=PROMPT):
        head = [{"type": "session_meta", "timestamp": AFTER,
                 "payload": {"id": session, "cwd": cwd or str(self.root)}}] if meta else []
        if prompt is not None:
            head.append({"type": "event_msg", "timestamp": AFTER, "payload": {
                "type": "item_completed",
                "item": {"type": "UserMessage", "content": [{"type": "text", "text": prompt}]}}})
        return self.log("rollout-2026-11-07T02-36-58-" + CODEX_SESSION + ".jsonl",
                        [*head, *records])

    def context(self, model="gpt-6.1-sol", effort="medium", at=AFTER):
        payload = {"model": model, "cwd": str(self.root)}
        if effort is not None:
            payload["effort"] = effort
        return {"type": "turn_context", "timestamp": at, "payload": payload}

    def observe(self, path, ok=True, prompt=PROMPT):
        extra = ("--launch-prompt", prompt) if prompt else ()
        return self.mutate("observe", "--transcript", str(path), *extra, ok=ok)

    def attempt(self):
        return self.call("show", self.task)["task"]["attempts"][-1]

    def receive(self):
        return self.mutate("receive", "--file", str(self.receive_file()))

    def accept(self, ok=True):
        log = self.directory / "check.log"
        log.write_text("synthetic controller check output")
        check = self.mutate("check", "--file", str(log), "--exit-status", "0",
                            "--note", "fixture check")["check"]["id"]
        return self.mutate("update", "--state", "accepted", "--note", "review",
                           "--evidence", "independent fixture review", "--check", check, ok=ok)

    def remote_start(self, kind="claude", model="sonnet"):
        self.start(kind=kind, model=model, route="herdr1", bind=False)
        self.mutate("bind", "--pane", "machine:mini-id#w1:p2")
        self.mutate("update", "--state", "running", "--note", "remote fixture",
                    "--evidence", str(self.evidence))

    def remote_observe(self, path, cwd="/Users/remote/task", ok=True, prompt=PROMPT):
        return self.mutate("observe", "--transcript", str(path),
                           "--launch-prompt", prompt, "--remote-cwd", cwd, ok=ok)

    def test_remote_claude_exact_cwd_allows_acceptance(self):
        self.remote_start()
        path = self.claude_log([self.turn()], cwd="/Users/remote/task")
        self.observe(path, ok=False)
        self.remote_observe(path)
        self.assertEqual(self.attempt()["observed_remote_cwd"], "/Users/remote/task")
        self.receive()
        self.accept()

    def test_remote_codex_exact_cwd_allows_acceptance(self):
        self.remote_start(kind="codex", model="gpt-6.1-sol")
        self.remote_observe(self.codex_log([self.context()], cwd="/Users/remote/task"))
        self.receive()
        self.accept()

    def test_remote_mismatch_including_child_cwd_revokes_previous_proof(self):
        self.remote_start()
        for actual in ("/Users/remote/other", "/Users/remote/task/child"):
            self.remote_observe(self.claude_log([self.turn()], cwd="/Users/remote/task"))
            self.remote_observe(self.claude_log([self.turn()], cwd=actual), ok=False)
            self.assertIsNone(self.attempt()["observed_model"])
        self.receive()
        self.accept(ok=False)

    def test_remote_preserves_prompt_session_time_and_pair_checks(self):
        self.remote_start()
        cases = [
            self.claude_log([self.turn()], cwd="/Users/remote/task", prompt="wrong"),
        ]
        self.remote_observe(cases[0], ok=False)
        for turns in ([self.turn(at=BEFORE)], [self.turn(effort=None)],
                      [self.turn(), self.turn(effort="high")],
                      [self.turn(sessionId=CODEX_SESSION)]):
            self.remote_observe(self.claude_log(turns, cwd="/Users/remote/task"), ok=False)
        self.remote_observe(self.claude_log([self.turn(model="claude-haiku-5-5")],
                                           cwd="/Users/remote/task"))
        self.receive()
        self.accept(ok=False)

    def test_remote_cwd_requires_explicit_remote_binding_and_absolute_path(self):
        self.start(route="herdr1")
        path = self.claude_log([self.turn()])
        self.assertIn("machine-qualified", self.remote_observe(path, ok=False)["error"])
        for cwd in ("relative", "/", "/a/../b", "/a/./b", "/a/"):
            self.assertIn("normalized absolute", self.remote_observe(path, cwd, ok=False)["error"])

    def test_terminal_routes_record_plan_bind_and_observe(self):
        for route in ("hc", "herdr1", "herdr"):
            with self.subTest(route=route):
                for kind in ("claude", "codex"):
                    self.task = self.call("new", "--owner", self.owner, "--topic", "Route fixture",
                                          "--cwd", str(self.root), "--scope", "fixture",
                                          "--acceptance", "pass")["task"]["id"]
                    plan = self.root / "launch-plan.json"
                    plan.write_text(json.dumps({"route": route}))
                    self.start(kind=kind, route=route, plan=plan)
                    attempt = self.attempt()
                    self.assertEqual(attempt["route"], route)
                    self.assertEqual(attempt["plan"], str(plan))
                    self.mutate("bind", "--session", "wrong-identity", ok=False)
                    self.mutate("bind", "--pane", "t2", "--model", "invented", ok=False)
                    self.mutate("bind", "--pane", "t2", "--effort", "low", ok=False)
                    log = (self.claude_log([self.turn()]) if kind == "claude"
                           else self.codex_log([self.context()]))
                    self.assertEqual(self.observe(log)["observed"]["effort"], "medium")

    def test_old_record_without_route_or_plan_still_binds_and_observes(self):
        self.start(bind=False)
        path = self.directory / "task.json"
        task = json.loads(path.read_text())
        task["attempts"][-1].pop("route")
        task["attempts"][-1].pop("plan")
        path.write_text(json.dumps(task))
        for flag, value in [("--model", "invented"), ("--effort", "low")]:
            error = self.mutate("bind", "--pane", "t2", flag, value, ok=False)
            self.assertIn("bind cannot record", error["error"])
        self.mutate("bind", "--pane", "t2")
        self.assertEqual(self.observe(self.claude_log([self.turn()]))["observed"]["effort"], "medium")

    def test_claude_consistent_value_allows_acceptance(self):
        self.start()
        path = self.claude_log([
            self.turn(model="claude-opus-5-5", effort="high", at=BEFORE),  # earlier attempt
            self.turn(),
            self.turn(model="<synthetic>", effort=None),
            self.turn(model="claude-haiku-5-5", effort="low", isSidechain=True),
            self.turn(),
        ])
        result = self.observe(path)
        self.assertEqual(result["observed"], {"model": "claude-sonnet-5-5", "effort": "medium"})
        attempt = result["task"]["attempts"][-1]
        self.assertEqual(attempt["observed_source"], str(path))
        self.assertEqual(attempt["observed_session"], CLAUDE_SESSION)
        self.receive()
        self.accept()

    def test_claude_raw_unicode_separators_allow_observation(self):
        self.start()
        for separator in ("\u0085", "\u2028", "\u2029"):
            with self.subTest(separator=repr(separator)):
                path = self.claude_log([self.turn()], prompt=PROMPT + separator + "tail")
                # json.dumps defaults to ASCII escapes, which mask this defect.
                path.write_text(path.read_text().replace(
                    json.dumps(separator)[1:-1], separator), encoding="utf-8")
                self.assertIn(separator.encode("utf-8"), path.read_bytes())
                result = self.observe(path, prompt=PROMPT + separator + "tail")
                self.assertEqual(result["observed"],
                                 {"model": "claude-sonnet-5-5", "effort": "medium"})

    def test_codex_raw_unicode_separators_allow_observation(self):
        self.start(kind="codex", model="gpt-6.1-sol")
        for separator in ("\u0085", "\u2028", "\u2029"):
            with self.subTest(separator=repr(separator)):
                path = self.codex_log([self.context()], prompt=PROMPT + separator + "tail")
                path.write_text(path.read_text().replace(
                    json.dumps(separator)[1:-1], separator), encoding="utf-8")
                self.assertIn(separator.encode("utf-8"), path.read_bytes())
                result = self.observe(path, prompt=PROMPT + separator + "tail")
                self.assertEqual(result["observed"],
                                 {"model": "gpt-6.1-sol", "effort": "medium"})

    def test_claude_model_switch_is_refused_and_clears_earlier_values(self):
        self.start()
        self.observe(self.claude_log([self.turn()]))
        error = self.observe(self.claude_log([self.turn(),
                                              self.turn(model="claude-opus-5-5")]), ok=False)
        self.assertIn("mixed", error["error"])
        self.assertIn("claude-opus-5-5 / medium", error["error"])
        self.assertIsNone(self.attempt()["observed_model"])
        self.receive()
        self.assertIn("model/effort", self.accept(ok=False)["error"])

    def test_claude_missing_values_are_refused(self):
        self.start()
        cases = {
            "no turn": [],
            "only an earlier attempt": [self.turn(at=BEFORE)],
            "missing effort": [self.turn(effort=None)],
            "missing timestamp": [{"type": "assistant", "sessionId": CLAUDE_SESSION,
                                   "message": {"model": "claude-sonnet-5-5"},
                                   "effort": "medium"}],
        }
        for label, records in cases.items():
            with self.subTest(label):
                self.observe(self.claude_log(records), ok=False)
                self.assertIsNone(self.attempt()["observed_effort"])

    def test_claude_log_from_elsewhere_is_refused(self):
        self.start()
        cases = {
            "not a session file name": ("named", lambda: self.claude_log([self.turn()], name="agent-x.jsonl")),
            "another session's entry": ("another session", lambda: self.claude_log(
                [dict(self.turn(), sessionId="00000000-0000-0000-0000-000000000000")])),
            "started outside the task": ("did not start", lambda: self.claude_log(
                [self.turn()], cwd="/elsewhere")),
        }
        for label, (reason, build) in cases.items():
            with self.subTest(label):
                self.assertIn(reason, self.observe(build(), ok=False)["error"])
        self.assertNotIn("observed_source", self.attempt())

    def test_codex_consistent_value_allows_acceptance(self):
        self.start(kind="codex", model="gpt-6.1-sol", effort="medium")
        path = self.codex_log([self.context(effort="xhigh", at=BEFORE),
                               self.context(), {"type": "event_msg", "timestamp": AFTER,
                                                "payload": {"type": "task_complete"}},
                               self.context()])
        result = self.observe(path)
        self.assertEqual(result["observed"], {"model": "gpt-6.1-sol", "effort": "medium"})
        self.assertEqual(result["task"]["attempts"][-1]["observed_session"], CODEX_SESSION)
        self.receive()
        self.accept()

    def test_codex_mixed_and_missing_values_are_refused(self):
        self.start(kind="codex", model="gpt-6.1-sol", effort="medium")
        cases = {
            "mixed effort": [self.context(), self.context(effort="xhigh")],
            "no turn_context": [],
            "missing effort": [self.context(effort=None)],
        }
        for label, records in cases.items():
            with self.subTest(label):
                error = self.observe(self.codex_log(records), ok=False)["error"]
                if label == "mixed effort":
                    self.assertIn("gpt-6.1-sol / xhigh", error)
        self.assertIsNone(self.attempt()["observed_model"])

    def test_codex_log_from_elsewhere_is_refused(self):
        self.start(kind="codex", model="gpt-6.1-sol", effort="medium")
        cases = {
            "session_meta of another session": ("session_meta", lambda: self.codex_log(
                [self.context()], session="00000000-0000-0000-0000-000000000000")),
            "started outside the task": ("did not start", lambda: self.codex_log(
                [self.context()], cwd="/elsewhere")),
            "no session_meta": ("session_meta", lambda: self.codex_log([self.context()], meta=False)),
            "not a rollout name": ("named", lambda: self.log(CODEX_SESSION + ".jsonl",
                                                          [self.context()])),
            "no launch prompt": ("first user message", lambda: self.codex_log(
                [self.context()], prompt=None)),
            "another launch prompt": ("launch prompt", lambda: self.codex_log(
                [self.context()], prompt="other task")),
        }
        for label, (reason, build) in cases.items():
            with self.subTest(label):
                self.assertIn(reason, self.observe(build(), ok=False)["error"])

    def test_controller_sharing_the_worker_cwd_is_not_the_worker(self):
        # Same project directory, both logs mention the brief path; only the
        # worker's log opens with the launch prompt.
        self.start()
        brief = {"type": "user", "sessionId": CLAUDE_SESSION, "timestamp": AFTER,
                 "message": {"content": "brief written: " + PROMPT}}
        controller = self.claude_log([brief, self.turn()],
                                     prompt="Run chief-of-staff for SH1-112")
        error = self.observe(controller, ok=False)["error"]
        self.assertIn("launch prompt", error)
        self.assertNotIn("observed_source", self.attempt())
        worker = self.claude_log([self.turn()], name="0" + CLAUDE_SESSION[1:] + ".jsonl")
        worker.write_text(worker.read_text().replace(CLAUDE_SESSION, worker.stem))
        self.assertEqual(self.observe(worker)["task"]["attempts"][-1]["observed_session"],
                         worker.stem)

    def test_launch_prompt_is_required_on_herdr(self):
        self.start()
        self.observe(self.claude_log([self.turn()]), prompt=None, ok=False)
        self.assertNotIn("observed_source", self.attempt())

    def test_observe_needs_a_bound_pane(self):
        self.start(bind=False)
        self.observe(self.claude_log([self.turn()]), ok=False)

    def test_receive_prints_the_envelope_once(self):
        self.start()
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "receive", self.task, "--owner", self.owner,
             "--file", str(self.receive_file())],
            env=self.env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual(set(output), {"task_id", "state", "envelope"})
        self.assertEqual(output["task_id"], self.task)
        self.assertEqual(output["state"], "reviewing")
        self.assertEqual(output["envelope"]["summary"], "fixture")
        self.assertEqual(result.stdout.count('"criteria"'), 1)
        self.assertEqual(self.call("show", self.task)["task"]["envelope"], output["envelope"])

    def receive_file(self):
        path = self.directory / "envelope.json"
        path.write_text(json.dumps(dict(
            task_id=self.task, attempt=1, status="done", summary="fixture",
            artifacts=[str(self.evidence)], open_questions=[],
            criteria=[dict(criterion="fixture check", status="pass",
                           evidence=str(self.evidence))])))
        return path


if __name__ == "__main__":
    unittest.main()
