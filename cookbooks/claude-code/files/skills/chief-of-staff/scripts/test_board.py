"""Agent Board (board.rb): sections, checklist, escaping, read-only, gates, gh cache.

The board reads a fixture ledger built here with invented data. Every
worker- or ledger-derived field carries HOSTILE markup tagged with the field
name, so the escaping test can show each one reaches the page as text.

The HTTP tests need the webrick gem. Without it for the test Ruby, the suite
installs it into a temporary directory (`gem install --install-dir`), or uses
COS_BOARD_TEST_GEM_HOME when that names a directory that already holds it.
"""

from datetime import datetime, timedelta, timezone
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import secrets
import select
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest


SCRIPTS = Path(__file__).resolve().parent
BOARD = SCRIPTS / "board.rb"
INBOX = SCRIPTS / "inbox.py"
RECIPE = SCRIPTS.parents[3] / "chief-of-staff-skill.rb"
RUBY = shutil.which("ruby")
NODE = shutil.which("node")
HOSTILE = "<img src=x onerror=alert(1)></script><script>alert(2)</script>&lt;\"'"
PR_RE = re.compile(r"^https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+/pull/[0-9]+$")
NOW = datetime.now(timezone.utc).replace(microsecond=0)


def mark(field):
    return f"{HOSTILE}#{field}"


def at(minutes_ago):
    return (NOW - timedelta(minutes=minutes_ago)).isoformat()


def task_id(n):
    return f"{n:016x}"


def fingerprint(root):
    """Every path under root with its type, mode, size, mtime and content hash."""
    result = {}
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in dirnames + filenames:
            path = Path(dirpath) / name
            info = os.lstat(path)
            digest = None
            if stat.S_ISREG(info.st_mode):
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
            result[str(path.relative_to(root))] = (stat.S_IFMT(info.st_mode), info.st_mode, info.st_size,
                                                   info.st_mtime_ns, digest)
        result[str(Path(dirpath).relative_to(root)) + "/"] = os.lstat(dirpath).st_mtime_ns
    return result


class Fixture:
    """An invented ledger: one task per section rule, plus hostile text."""

    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.nonces = {}
        self.ids = {}

    def write(self, path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body if isinstance(body, str) else json.dumps(body), encoding="utf-8")

    def task(self, n, name, state, attempts=1, kind="claude", updated=5, **extra):
        tid = task_id(n)
        self.ids[name] = tid
        directory = self.root / tid
        attempt_list = []
        for number in range(1, attempts + 1):
            nonce = secrets.token_hex(8)
            self.nonces[(tid, number)] = nonce
            attempt_list.append({"number": number, "agent": extra.pop("agent", f"worker-{name}-{number}")
                                 if number == attempts else f"old-{number}", "kind": kind,
                                 "route": "hc", "pane": None, "terminal_id": extra.pop("terminal", f"t{n}"),
                                 "created_at": at(120 - number), "nonce": nonce})
        body = {
            "id": tid, "owner": extra.pop("owner", "hc:default#t1"), "topic": extra.pop("topic", f"Topic {name}"),
            "cwd": "/tmp", "scope": "Local", "acceptance": extra.pop("acceptance", ["Criterion one", "Criterion two"]),
            "state": state, "max_attempts": 3, "attempts": attempt_list,
            "history": extra.pop("history", [{"at": at(119), "state": "queued", "note": "created"}]),
            "fresh_worker": True, "contract": "envelope-v1", "created_at": at(120),
            "last_report": extra.pop("last_report", None), "report_pending": False, "updated_at": at(updated),
        }
        body.update(extra)
        self.write(directory / "task.json", body)
        return directory

    def inbox(self, name, kind, text, minutes_ago, on=None, step=None, read=False, attempt=1):
        tid = self.ids[name]
        body = {"task_id": tid, "attempt": attempt, "nonce": self.nonces[(tid, attempt)], "kind": kind,
                "text": text, "on": on, "step": step, "at": at(minutes_ago)}
        ns = int((NOW - timedelta(minutes=minutes_ago)).timestamp() * 1e9)
        box = self.root / tid / "inbox" / ("read" if read else "")
        self.write(box / f"{attempt}-{ns}-{secrets.token_hex(8)}.json", body)

    def state(self, name, attempt=1, **fields):
        tid = self.ids[name]
        body = {"provenance": "fixture", "task_id": tid, "attempt": attempt, "status": "working",
                "updated_at": at(1), "last_event": "PostToolUse", "session_id": "fixture-session-1",
                "blocked": None, "asking": None, "error": None, "ended": None, "milestones": []}
        body.update(fields)
        self.write(self.root / tid / f"state-{attempt}.json", body)

    def checklist(self, name, items, attempt=1):
        tid = self.ids[name]
        result = subprocess.run(
            [sys.executable, str(INBOX), "tasks", "--task-dir", str(self.root / tid), "--task-id", tid,
             "--attempt", str(attempt), "--nonce", self.nonces[(tid, attempt)], "--items", json.dumps(items)],
            text=True, capture_output=True, timeout=20)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)


def build(root, hostile=True):
    """The standard fixture. Returns the Fixture."""
    h = mark if hostile else (lambda field: f"plain {field}")
    f = Fixture(root)
    gh_url = "https://github.com/example-org/demo-repo/pull/12"
    merged_url = "https://github.com/example-org/demo-repo/pull/2"
    f.task(1, "needs", "needs-user", topic=h("topic"), owner="hc:default#" + h("tag"), agent=h("agent"),
           terminal=h("terminal"),
           history=[{"at": at(110), "state": "running", "note": h("history")},
                    {"at": at(30), "state": "needs-user", "note": h("need")}],
           last_report={"at": at(25), "note": h("controller-report")},
           pr=[{"url": gh_url, "repo": "example-org/demo-repo", "number": 12, "added_at": at(40)},
               {"url": "javascript:alert(1)//github.com/x/y/pull/1", "repo": "x", "number": 1,
                "added_at": at(39)}])
    f.write(f.root / task_id(1) / "launch-prompt-1.txt", h("prompt"))
    f.state("needs", status="idle", milestones=[
        {"at": at(50), "kind": "commit", "sha": "abc1234def", "subject": h("commit")},
        {"at": at(45), "kind": "test-failed", "command": h("test-command"), "exit_code": 1},
        {"at": at(44), "kind": "pr", "url": merged_url}])
    f.inbox("needs", "step", h("step-read"), 60, step="1/3", read=True)
    f.inbox("needs", "note", h("note-unread"), 20)
    f.checklist("needs", [{"text": h("item"), "state": "doing",
                           "children": [{"text": h("child"), "state": "todo"},
                                        {"text": "Write the failing test", "state": "doing"}]},
                          {"text": "Open the draft PR", "state": "todo"}])
    f.checklist("needs", [{"text": h("item"), "state": "doing",
                           "children": [{"text": h("child"), "state": "done"},
                                        {"text": "Write the failing test", "state": "done"}]},
                          {"text": "Open the draft PR", "state": "failed"}])

    f.task(2, "blocked", "running")
    f.state("blocked", status="blocked", blocked={"tool": "Bash", "command": h("blocked"), "at": at(2)})
    f.write(f.root / task_id(2) / "digest-1.json",
            {"provenance": "fixture", "attempt": 1, "at": at(2), "did": h("did"), "now": "waiting",
             "decide": h("decide")})

    f.task(3, "asking", "running")
    f.state("asking", status="asking", updated_at=at(2), asking={"tool": None, "question": h("asking"), "at": at(2)})

    f.task(4, "waiting-owner", "running")
    f.inbox("waiting-owner", "wait", h("wait"), 3, on=f"the owner {HOSTILE}"[:80])

    f.task(5, "codex", "running", kind="codex", owner="hc:default#t10",
           acceptance=[h("criterion"), "Second criterion"])
    f.inbox("codex", "question", "Which branch should I use?", 4)  # to the controller: still working

    f.task(6, "accepted-recent", "accepted", updated=60, owner="hc:default#t10",
           acceptance=["Passes A", "Passes B", "Passes C"],
           envelope={"task_id": task_id(6), "attempt": 1, "status": "done", "summary": "s", "artifacts": [],
                     "criteria": [{"criterion": "Passes A", "status": "pass", "evidence": "/x"},
                                  {"criterion": "Passes B", "status": "fail", "evidence": "/x"},
                                  {"criterion": "Passes C", "status": "unverified", "evidence": "/x"}],
                     "open_questions": []})
    f.task(7, "accepted-old", "accepted", updated=3 * 24 * 60)
    f.task(8, "cancelled", "cancelled", updated=90, owner="hc:default#t10")
    f.task(9, "queued", "queued", attempts=0, owner=None, updated=7)

    f.task(10, "bad-nonce", "running", owner=h("group"), updated=8)
    f.write(f.root / task_id(10) / "checklist-1.json",
            {"task_id": task_id(10), "attempt": 1, "nonce": "0" * 16, "at": at(5), "started_at": at(5),
             "items": [{"text": "forged item", "state": "done"}], "changes": []})
    return f


def add_malformed(root):
    """Broken ledger files next to the good fixture; returns their task IDs."""
    root = Path(root)
    bad = {}

    def make(n, name):
        tid = task_id(0xBAD000 + n)
        (root / tid).mkdir()
        bad[name] = tid
        return root / tid

    good = json.dumps({"id": task_id(0xBAD000 + 1), "state": "running", "topic": "t", "attempts": []})
    (make(1, "truncated") / "task.json").write_text(good[: len(good) // 2])
    (make(2, "not-json") / "task.json").write_text("\x00\xff not json")
    (make(3, "array") / "task.json").write_text("[1, 2, 3]")
    os.mkfifo(make(4, "fifo") / "task.json")
    (make(5, "symlink") / "task.json").symlink_to(root / task_id(1) / "task.json")
    (make(6, "huge") / "task.json").write_text(" " * (4 * 1024 * 1024 + 10))
    (make(7, "wrong-id") / "task.json").write_text(json.dumps({"id": task_id(1), "state": "running"}))
    directory = make(8, "odd-fields")
    (directory / "task.json").write_text(json.dumps({
        "id": task_id(0xBAD000 + 8), "state": 7, "topic": ["x"], "attempts": "nope", "history": "x",
        "acceptance": {"a": 1}, "pr": "x", "last_report": [], "updated_at": "yesterday"}))
    directory = make(9, "bad-components")
    (directory / "task.json").write_text(json.dumps({
        "id": task_id(0xBAD000 + 9), "state": "running", "topic": "components",
        "attempts": [{"agent": "w", "kind": "claude", "nonce": "1" * 16, "created_at": "bad"}],
        "history": [{"at": 5}], "acceptance": ["ok"]}))
    (directory / "state-1.json").write_text("{\"attempt\": 1, \"status\": ")
    (directory / "checklist-1.json").write_text("{")
    (directory / "inbox").mkdir()
    (directory / "inbox" / "1-123-abcdef0123456789.json").write_text("garbage")
    os.mkfifo(directory / "inbox" / "1-124-abcdef0123456789.json")
    os.mkfifo(directory / "launch-prompt-1.txt")
    real = root / "elsewhere"
    real.mkdir()
    (real / "task.json").write_text(json.dumps({"id": task_id(0xBAD000 + 10), "state": "running"}))
    (root / task_id(0xBAD000 + 10)).symlink_to(real)
    bad["dir-symlink"] = task_id(0xBAD000 + 10)
    (root / "journal").mkdir()
    (root / "not-a-task").write_text("x")
    return bad


def ruby_env(extra=None):
    env = dict(os.environ)
    env.pop("COS_STATE_DIR", None)
    env.update(extra or {})
    return env


class BoardCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not RUBY:
            raise unittest.SkipTest("ruby is not on PATH")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.state = self.base / "state"
        self.fixture = build(self.state)

    def run_board(self, *args, env=None, timeout=60, ok=True):
        result = subprocess.run([RUBY, str(BOARD), *args], env=ruby_env(env), text=True,
                                capture_output=True, timeout=timeout)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def dump(self, *args, root=None, env=None):
        result = self.run_board("--dump-json", "--state-dir", str(root or self.state), *args,
                                env=env or {}, timeout=60)
        return json.loads(result.stdout)

    def rows(self, data):
        rows = data["needs_you"] + [row for group in data["groups"] for row in group["rows"]]
        return {row["id"]: row for row in rows}


class SectionTest(BoardCase):
    def test_every_owner_every_section(self):
        data = self.dump("--no-gh")
        ids = self.fixture.ids
        section = {row["id"]: row["section"] for row in self.rows(data).values()}
        self.assertEqual(len(section), 10, "every ledger task, of every owner, appears once")
        count = len(data["needs_you"]) + sum(len(g["rows"]) for g in data["groups"])
        self.assertEqual(count, 10, "no task is listed twice")
        for name in ("needs", "blocked", "asking", "waiting-owner"):
            self.assertEqual(section[ids[name]], "needs_you", name)
        for name in ("codex", "queued", "bad-nonce"):
            self.assertEqual(section[ids[name]], "working", name)
        for name in ("accepted-recent", "accepted-old", "cancelled"):
            self.assertEqual(section[ids[name]], "idle", name)
        rows = self.rows(data)
        self.assertTrue(rows[ids["accepted-recent"]]["recent"])
        self.assertFalse(rows[ids["accepted-old"]]["recent"], "idle older than 24 h is hidden by default")
        self.assertEqual(data["errors"], [])

    def test_grouped_by_controller(self):
        data = self.dump("--no-gh")
        ids = self.fixture.ids
        names = {tid: name for name, tid in ids.items()}
        self.assertEqual([names[r["id"]] for r in data["needs_you"]], ["needs", "blocked", "asking", "waiting-owner"],
                         "one Needs you list across controllers, newest first")
        tags = {names[r["id"]]: r["controller_tag"] for r in data["needs_you"]}
        self.assertEqual(tags, {"needs": mark("tag"), "blocked": "t1", "asking": "t1", "waiting-owner": "t1"})
        self.assertEqual([g["label"] for g in data["groups"]],
                         ["hc:default#t10", "(no controller key)", mark("group"), "hc:default#t1"],
                         "groups ordered by most recent update; tasks without a key share one group")
        self.assertEqual([g["owner"] for g in data["groups"]][1], None)
        members = {g["label"]: [(names[r["id"]], r["section"]) for r in g["rows"]] for g in data["groups"]}
        self.assertEqual(members["hc:default#t10"],
                         [("codex", "working"), ("accepted-recent", "idle"), ("cancelled", "idle")],
                         "working rows first, then idle, each newest first")
        self.assertEqual(members["hc:default#t1"], [("accepted-old", "idle")])
        for group in data["groups"]:
            self.assertTrue(all(r["owner"] == group["owner"] for r in group["rows"]))
            self.assertTrue(all(r["section"] != "needs_you" for r in group["rows"]))

    def test_row_fields(self):
        rows = self.rows(self.dump("--no-gh"))
        needs = rows[self.fixture.ids["needs"]]
        self.assertEqual(needs["agent"], mark("agent"))
        self.assertEqual(needs["topic"], mark("topic"))
        self.assertTrue(needs["need"].startswith(mark("need")))
        self.assertEqual([p["label"] for p in needs["prs"]], ["demo-repo#12", "demo-repo#2"],
                         "ledger PRs and state-file PR milestones; the javascript: URL is dropped")
        self.assertTrue(all(PR_RE.match(p["url"]) for p in needs["prs"]))
        self.assertTrue(needs["updated_at"])
        codex = rows[self.fixture.ids["codex"]]
        self.assertEqual(codex["kind"], "codex")
        self.assertIn({"label": "Status", "value": "no state file (Codex worker)"}, codex["facts"])
        self.assertEqual(codex["tasks"]["source"], "acceptance")
        blocked = rows[self.fixture.ids["blocked"]]
        self.assertIn(mark("blocked"), blocked["need"])
        self.assertIn(mark("decide"), blocked["need"])
        facts = {f["label"]: f for f in needs["facts"]}
        self.assertEqual(facts["Controller"]["value"], "hc:default#" + mark("tag"))
        self.assertIn(mark("terminal"), facts["Lane"]["value"])
        self.assertTrue(facts["Status"]["at"])

    def test_checklist_two_levels_and_timeline(self):
        rows = self.rows(self.dump("--no-gh"))
        needs = rows[self.fixture.ids["needs"]]
        tasks = needs["tasks"]
        self.assertEqual(tasks["source"], "checklist")
        self.assertEqual(tasks["items"][0]["text"], mark("item"))
        self.assertEqual([c["state"] for c in tasks["items"][0]["children"]], ["done", "done"])
        self.assertEqual(tasks["progress"], {"todo": 0, "doing": 0, "done": 2, "failed": 1, "total": 3})
        texts = [t["text"] for t in needs["timeline"]]
        self.assertIn("Write the failing test → done", texts)
        self.assertIn("Open the draft PR → failed", texts)
        self.assertIn("Plan: 3 tasks", texts)
        self.assertIn(f"From chief-of-staff {mark('prompt')}", texts)
        self.assertTrue(any(t.startswith("Commit abc1234 ") for t in texts))
        self.assertTrue(any(t.startswith("Test failed (exit 1): ") for t in texts))
        self.assertTrue(any(t.startswith("PR demo-repo#12 opened") for t in texts))
        self.assertTrue(any(t.startswith("Step 1/3 ") for t in texts), "read inbox messages count")
        self.assertTrue(any(t.startswith("Note ") for t in texts), "unread inbox messages count")
        self.assertTrue(any(t.startswith("Ledger → needs-user") for t in texts))
        stamps = [t["at"] for t in needs["timeline"]]
        self.assertEqual(stamps, sorted(stamps, reverse=True), "newest first")
        self.assertEqual(needs["last_report"]["text"], mark("note-unread"))

    def test_forged_checklist_nonce_is_not_shown(self):
        row = self.rows(self.dump("--no-gh"))[self.fixture.ids["bad-nonce"]]
        self.assertEqual(row["tasks"]["source"], "acceptance")
        self.assertEqual(row["tasks"]["note"], "checklist nonce does not match the current attempt")
        self.assertNotIn("forged item", json.dumps(row))

    def test_acceptance_marks_from_envelope(self):
        row = self.rows(self.dump("--no-gh"))[self.fixture.ids["accepted-recent"]]
        self.assertEqual([(i["text"], i["mark"]) for i in row["tasks"]["items"]],
                         [("Passes A", "pass"), ("Passes B", "fail"), ("Passes C", "unverified")])
        queued = self.rows(self.dump("--no-gh"))[self.fixture.ids["queued"]]
        self.assertEqual([i["mark"] for i in queued["tasks"]["items"]], [None, None])

    def test_question_to_controller_is_not_needs_you(self):
        row = self.rows(self.dump("--no-gh"))[self.fixture.ids["codex"]]
        self.assertEqual(row["section"], "working")


class MalformedTest(BoardCase):
    def test_broken_files_leave_the_rest_served(self):
        bad = add_malformed(self.state)
        data = self.dump("--no-gh")
        rows = self.rows(data)
        for name, tid in self.fixture.ids.items():
            self.assertIn(tid, rows, name)
        unreadable = {e["task"]: e["reason"] for e in data["errors"]}
        for name in ("truncated", "not-json", "array", "fifo", "symlink", "huge", "wrong-id", "dir-symlink"):
            self.assertIn(bad[name], unreadable, name)
        self.assertIn("truncated or mid-rewrite", unreadable[bad["truncated"]])
        self.assertIn("exceeds 4194304 bytes", unreadable[bad["huge"]], "reads stop at the size cap")
        self.assertIn("not a regular file", unreadable[bad["fifo"]])
        # Odd field types and broken component files degrade inside the row.
        self.assertIn(bad["odd-fields"], rows)
        components = rows[bad["bad-components"]]
        self.assertEqual(components["tasks"]["source"], "acceptance")
        self.assertIn({"label": "Status", "value": "no state file"}, components["facts"])

    def test_concurrent_rewrite(self):
        target = self.state / self.fixture.ids["blocked"] / "task.json"
        original = target.read_text()
        stop = threading.Event()

        def rewrite():
            while not stop.is_set():
                with target.open("w") as handle:  # in place, not atomic: readers see partial files
                    handle.write(original[: len(original) // 3])
                    handle.flush()
                    time.sleep(0.002)
                    handle.write(original[len(original) // 3:])

        thread = threading.Thread(target=rewrite)
        thread.start()
        try:
            for _ in range(12):
                data = self.dump("--no-gh")
                rows = self.rows(data)
                for name, tid in self.fixture.ids.items():
                    if name != "blocked":
                        self.assertIn(tid, rows, name)
        finally:
            stop.set()
            thread.join()


class ReadOnlyTest(BoardCase):
    def test_dump_and_snapshot_leave_state_untouched(self):
        add_malformed(self.state)
        before = fingerprint(self.state)
        self.dump("--no-gh")
        out = self.base / "out" / "board.html"
        out.parent.mkdir()
        self.run_board("--snapshot", str(out), "--no-gh", "--state-dir", str(self.state))
        self.assertTrue(out.is_file())
        self.assertEqual(fingerprint(self.state), before)

    def test_snapshot_refuses_the_state_directory(self):
        before = fingerprint(self.state)
        for target in (self.state / "board.html", self.state / self.fixture.ids["needs"] / "b.html"):
            result = self.run_board("--snapshot", str(target), "--no-gh", "--state-dir", str(self.state),
                                    ok=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("outside the state directory", result.stderr)
        self.assertEqual(fingerprint(self.state), before)


class EscapingTest(BoardCase):
    FIELDS = ("topic", "agent", "tag", "group", "terminal", "need", "history", "controller-report", "prompt",
              "commit", "test-command", "step-read", "note-unread", "item", "child", "blocked", "decide",
              "asking", "wait", "criterion")

    def snapshot(self):
        out = self.base / "board.html"
        self.run_board("--snapshot", str(out), "--no-gh", "--state-dir", str(self.state))
        return out, out.read_text(encoding="utf-8")

    def test_every_field_carries_the_markup_as_data(self):
        strings = []

        def collect(value):
            if isinstance(value, dict):
                for item in value.values():
                    collect(item)
            elif isinstance(value, list):
                for item in value:
                    collect(item)
            elif isinstance(value, str):
                strings.append(value)

        collect(self.dump("--no-gh"))
        for field in self.FIELDS:
            self.assertTrue(any(mark(field) in value for value in strings), field)

    def test_snapshot_html_has_no_raw_markup(self):
        _, html = self.snapshot()
        self.assertEqual(html.count("<script"), 2, "only the data block and the page script")
        self.assertEqual(html.count("</script"), 2)
        self.assertNotIn("<img", html)
        embedded = re.search(r'<script id="board-data" type="application/json">(.*?)</script>', html, re.S).group(1)
        self.assertNotIn("<", embedded)
        self.assertNotIn(">", embedded)
        data = json.loads(embedded)
        self.assertEqual(self.rows(data).keys(), self.rows(self.dump("--no-gh")).keys())

    def test_page_script_never_parses_html(self):
        source = BOARD.read_text(encoding="utf-8")
        script = source[source.index("JS = <<~'JS'"):source.index("\n  JS\n")]
        for sink in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "Function(",
                     "setAttribute(\"on", "srcdoc", "javascript:"):
            self.assertNotIn(sink, script, sink)

    @unittest.skipUnless(NODE, "node is not on PATH")
    def test_rendered_dom_keeps_markup_as_text(self):
        out, _ = self.snapshot()
        harness = self.base / "harness.js"
        harness.write_text(DOM_HARNESS, encoding="utf-8")
        result = subprocess.run([NODE, str(harness), str(out)], text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertLessEqual(set(report["tags"]), {"DIV", "SPAN", "SECTION", "H2", "H3", "UL", "LI", "A", "P",
                                                   "TIME", "DL", "DT", "DD", "BUTTON"})
        self.assertLessEqual(set(report["attributes"]), {"role", "aria-expanded", "datetime", "title"})
        self.assertIn("hc:default#" + mark("tag"), report["titles"], "the Needs you tag carries the full key as a title")
        self.assertIn("[" + mark("tag") + "]", report["texts"])
        self.assertIn(mark("group"), report["texts"], "the group heading shows the key as text")
        self.assertIn("1 working \u00b7 2 idle", report["texts"])
        self.assertNotIn("hc:default#t1", report["initial_groups"], "an all-hidden idle group is not shown")
        self.assertIn("hc:default#t1", report["final_groups"])
        self.assertEqual(report["initial_groups"][0], "hc:default#t10")
        self.assertTrue(report["hrefs"])
        for href in report["hrefs"]:
            self.assertRegex(href, PR_RE)
        texts = "\n".join(report["texts"])
        for field in self.FIELDS:
            self.assertIn(mark(field), texts, field)
        self.assertGreater(report["expanded"], 8)


# A minimal DOM: elements only through createElement, text only through
# textContent; innerHTML throws. It runs the page script on a snapshot,
# expands every row and every "Show N more", and reports what was built.
DOM_HARNESS = r"""
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");
const data = html.match(/<script id="board-data" type="application\/json">([\s\S]*?)<\/script>/)[1];
const script = html.match(/<script nonce="[0-9a-f]+">([\s\S]*?)<\/script>/)[1];
const all = [];
class El {
  constructor(tag) { this.tagName = tag.toUpperCase(); this.children = []; this.text = null;
    this.attributes = {}; this.listeners = {}; this.style = {}; this.className = ""; all.push(this); }
  get textContent() { return this.text !== null ? this.text : this.children.map(c => c.textContent).join(""); }
  set textContent(v) { this.children = []; this.text = String(v); }
  set innerHTML(v) { throw new Error("innerHTML used"); }
  get innerHTML() { throw new Error("innerHTML used"); }
  set outerHTML(v) { throw new Error("outerHTML used"); }
  insertAdjacentHTML() { throw new Error("insertAdjacentHTML used"); }
  appendChild(c) { if (!(c instanceof El)) throw new Error("non-element child"); this.children.push(c); return c; }
  replaceChildren(...c) { this.children = []; this.text = null; c.forEach(x => this.appendChild(x)); }
  setAttribute(k, v) { this.attributes[k] = String(v); }
  addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); }
  fire(t) { (this.listeners[t] || []).forEach(f => f({ key: "Enter", stopPropagation() {}, preventDefault() {} })); }
}
const ids = {};
for (const id of ["count", "status", "board", "errors"]) ids[id] = new El("div");
ids["board-data"] = { textContent: data };
const document = { createElement: t => new El(t), getElementById: id => ids[id],
  write() { throw new Error("document.write used"); } };
new Function("document", "fetch", script)(document, () => { throw new Error("snapshot fetched"); });
function walk(node, out) { out.push(node); node.children.forEach(c => walk(c, out)); return out; }
function live() { return walk(ids.board, []); }
const initial_groups = live().filter(n => n.className === "key").map(n => n.textContent);
let expanded = 0;
for (let guard = 0; guard < 500; guard++) {
  const closed = live().find(n => n.attributes["aria-expanded"] === "false");
  const more = live().find(n => n.tagName === "BUTTON" && /^Show (all idle|[0-9]+ more)/.test(n.textContent));
  if (more) { more.fire("click"); continue; }
  if (!closed) break;
  closed.fire("click"); expanded++;
}
const groupKeys = () => live().filter(n => n.className === "key").map(n => n.textContent);
const final_groups = groupKeys();
const nodes = live().concat(walk(ids.errors, []), [ids.count]);
const report = { tags: [...new Set(nodes.map(n => n.tagName))],
  attributes: [...new Set(nodes.flatMap(n => Object.keys(n.attributes)))],
  hrefs: nodes.filter(n => n.href !== undefined).map(n => n.href),
  texts: nodes.filter(n => n.text !== null).map(n => n.text), expanded, initial_groups, final_groups,
  titles: nodes.map(n => n.attributes.title).filter(Boolean) };
for (const n of nodes) for (const key of Object.keys(n))
  if (/^on/i.test(key)) throw new Error("event handler property " + key);
process.stdout.write(JSON.stringify(report));
"""


class CommandLineTest(BoardCase):
    def test_missing_webrick_is_one_line(self):
        result = subprocess.run([RUBY, "--disable-gems", str(BOARD), "--no-gh", "--port", "0",
                                 "--state-dir", str(self.state)], env=ruby_env(), text=True,
                                capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(result.stderr.strip().splitlines()), 1, result.stderr)
        self.assertIn("webrick gem is missing", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_state_dir_falls_back_to_environment(self):
        result = self.run_board("--dump-json", "--no-gh", env={"COS_STATE_DIR": str(self.state)})
        self.assertEqual(len(self.rows(json.loads(result.stdout))), 10)
        explicit = self.run_board("--dump-json", "--no-gh", "--state-dir", str(self.state),
                                  env={"COS_STATE_DIR": str(self.base / "missing")})
        self.assertEqual(len(self.rows(json.loads(explicit.stdout))), 10, "--state-dir wins")


def webrick_env():
    """Environment in which the test Ruby can load webrick, or None."""
    probe = [RUBY, "-e", "require 'webrick'"]
    if subprocess.run(probe, env=ruby_env(), capture_output=True).returncode == 0:
        return {}
    paths = subprocess.run([RUBY, "-e", "print Gem.path.join(File::PATH_SEPARATOR)"], env=ruby_env(),
                           text=True, capture_output=True).stdout
    candidates = [os.environ.get("COS_BOARD_TEST_GEM_HOME"), str(Path(tempfile.gettempdir()) / "cos-board-gems")]
    for candidate in filter(None, candidates):
        env = {"GEM_PATH": candidate + os.pathsep + paths}
        if Path(candidate).is_dir() and subprocess.run(probe, env=ruby_env(env), capture_output=True).returncode == 0:
            return env
    target = tempfile.mkdtemp(prefix="cos-board-gems-")
    install = subprocess.run([RUBY, "-S", "gem", "install", "--no-document", "--install-dir", target, "webrick"],
                             env=ruby_env(), capture_output=True, text=True, timeout=300)
    env = {"GEM_PATH": target + os.pathsep + paths}
    if install.returncode == 0 and subprocess.run(probe, env=ruby_env(env), capture_output=True).returncode == 0:
        return env
    return None


FAKE_GH = """#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_GH_LOG"
case "$FAKE_GH_MODE" in
  fail) echo "gh: not logged in" >&2; exit 1 ;;
  hang) sleep 30 ;;
esac
case "$3" in
  */pull/2) printf '%s\\n' '{"isDraft":false,"state":"MERGED","mergedAt":"2026-01-01T00:00:00Z","reviewDecision":"","statusCheckRollup":[]}' ;;
  *) printf '%s\\n' '{"isDraft":true,"state":"OPEN","mergedAt":null,"reviewDecision":"REVIEW_REQUIRED","statusCheckRollup":[{"status":"IN_PROGRESS","conclusion":""},{"status":"COMPLETED","conclusion":"SUCCESS"}]}' ;;
esac
"""


class ServerBase(BoardCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.webrick = webrick_env()
        if cls.webrick is None:
            raise unittest.SkipTest("webrick is not available and could not be installed")

    def setUp(self):
        super().setUp()
        self.bin = self.base / "bin"
        self.bin.mkdir()
        gh = self.bin / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        self.gh_log = self.base / "gh.log"

    def start(self, *args, mode="ok"):
        env = ruby_env(dict(self.webrick, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
                            FAKE_GH_LOG=str(self.gh_log), FAKE_GH_MODE=mode))
        process = subprocess.Popen([RUBY, str(BOARD), "--port", "0", "--state-dir", str(self.state), *args],
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

        def stop():
            process.terminate()
            try:
                process.wait(10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(10)
            process.stdout.close()
            process.stderr.close()

        self.addCleanup(stop)
        self.process = process
        ready, _, _ = select.select([process.stdout], [], [], 30)
        self.assertTrue(ready, "server did not start")
        line = process.stdout.readline()
        match = re.match(r"Agent Board: http://127\.0\.0\.1:([0-9]+)/#t=([0-9a-f]{32}) ", line)
        self.assertTrue(match, line + process.stderr.read() if process.poll() is not None else line)
        self.token = match.group(2)
        return int(match.group(1))

    def request(self, port, method="GET", path="/api/board", host=None, token=True):
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
        try:
            connection.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
            connection.putheader("Host", host if host is not None else f"127.0.0.1:{port}")
            if token is True:
                connection.putheader("X-Board-Token", self.token)
            elif token is not None:
                connection.putheader("X-Board-Token", token)
            connection.endheaders()
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def gh_calls(self):
        return self.gh_log.read_text().splitlines() if self.gh_log.exists() else []


class ServerTest(ServerBase):
    def test_page_and_json(self):
        port = self.start("--no-gh")
        status, headers, body = self.request(port, path="/")
        self.assertEqual(status, 200)
        self.assertIn("default-src 'none'", headers["Content-Security-Policy"])
        self.assertIn("<title>Agent Board</title>", body.decode())
        self.assertIn('<script id="board-data" type="application/json">null</script>', body.decode())
        status, headers, body = self.request(port)
        self.assertEqual(status, 200)
        self.assertTrue(headers["Content-Type"].startswith("application/json"))
        self.assertEqual(len(self.rows(json.loads(body))), 10)
        self.assertEqual(self.request(port, path="/nope")[0], 404)

    def test_board_data_needs_the_run_token(self):
        port = self.start("--no-gh")
        wrong = "0" * 32 if self.token != "0" * 32 else "1" * 32
        for token in (None, "", wrong, self.token[:-1], self.token + "0", self.token.upper()):
            status, _, body = self.request(port, token=token)
            self.assertEqual(status, 403, token)
            self.assertNotIn(b"sections", body)
            self.assertNotIn(self.token.encode(), body)
        status, _, body = self.request(port)
        self.assertEqual(status, 200)
        self.assertEqual(len(self.rows(json.loads(body))), 10)
        # The page shell needs no token and holds no data, nor the token.
        status, _, page = self.request(port, path="/", token=None)
        self.assertEqual(status, 200)
        self.assertIn(b'<script id="board-data" type="application/json">null</script>', page)
        self.assertNotIn(self.token.encode(), page)
        self.assertIn(b'"X-Board-Token": token', page)
        # A second run gets a different token; the old one is refused.
        old = self.token
        second = self.start("--no-gh")
        self.assertNotEqual(self.token, old)
        self.assertEqual(self.request(second, token=old)[0], 403)
        self.process.terminate()
        self.process.wait(10)
        self.assertNotIn(self.token, self.process.stderr.read(), "the token is never logged")

    def test_poll_interval_is_at_most_ten_seconds(self):
        port = self.start("--no-gh")
        data = json.loads(self.request(port)[2])
        self.assertLessEqual(data["poll_seconds"], 10)
        page = self.request(port, path="/")[2].decode()
        poll = int(re.search(r"var POLL_MS = ([0-9]+);", page).group(1))
        self.assertLessEqual(poll, 10000)
        self.assertIn('fetch("api/board"', page)
        self.assertIn("setTimeout(poll, POLL_MS)", page)

    def test_host_header_must_be_loopback(self):
        port = self.start("--no-gh")
        for host in (f"127.0.0.1:{port}", "localhost", f"localhost:{port}", f"[::1]:{port}", "127.0.0.2"):
            self.assertEqual(self.request(port, host=host)[0], 200, host)
        for host in ("evil.example", f"evil.example:{port}", "127.0.0.1.evil.example", "localhost.evil.example",
                     "0.0.0.0", "[::ffff:127.0.0.1]", "", "127.0.0.1:80@evil.example", "localhost."):
            status, _, body = self.request(port, host=host)
            self.assertEqual(status, 403, host)
            self.assertNotIn(b"sections", body)
        with socket.create_connection(("127.0.0.1", port), timeout=20) as raw:
            raw.sendall(b"GET /api/board HTTP/1.0\r\n\r\n")
            reply = raw.recv(4096)
        self.assertRegex(reply[:20], rb"^HTTP/1\.[01] 403", "no Host header")

    def test_only_get_is_answered(self):
        port = self.start("--no-gh")
        before = fingerprint(self.state)
        for method in ("POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD", "PROPFIND"):
            for path in ("/", "/api/board", "*"):
                status, headers, body = self.request(port, method=method, path=path)
                self.assertEqual(status, 405, (method, path))
                self.assertEqual(headers.get("Allow"), "GET")
                self.assertNotIn(b"sections", body)
        self.assertEqual(fingerprint(self.state), before)

    def test_server_never_writes_state(self):
        add_malformed(self.state)
        before = fingerprint(self.state)
        port = self.start()
        for _ in range(3):
            self.request(port)
            self.request(port, path="/")
            time.sleep(0.3)
        self.assertEqual(fingerprint(self.state), before)

    def test_gh_state_is_cached(self):
        port = self.start()
        url = "https://github.com/example-org/demo-repo/pull/12"
        first = self.rows(json.loads(self.request(port)[2]))[self.fixture.ids["needs"]]
        self.assertTrue(all(p["state"] is None for p in first["prs"]), "the first answer does not wait for gh")
        deadline = time.time() + 20
        while time.time() < deadline and len(self.gh_calls()) < 2:
            time.sleep(0.1)
        time.sleep(0.5)
        for _ in range(4):
            row = self.rows(json.loads(self.request(port)[2]))[self.fixture.ids["needs"]]
        states = {p["label"]: p["state"] for p in row["prs"]}
        self.assertEqual(states["demo-repo#12"], "draft · CI pending · review requested")
        self.assertEqual(states["demo-repo#2"], "merged")
        calls = self.gh_calls()
        self.assertEqual(len(calls), 2, calls)
        self.assertIn(f"pr view {url} --json", calls[0] + calls[1])

    def test_gh_failure_and_no_gh_fall_back_to_links(self):
        port = self.start(mode="fail")
        self.request(port)
        deadline = time.time() + 20
        while time.time() < deadline and len(self.gh_calls()) < 2:
            time.sleep(0.1)
        time.sleep(0.5)
        row = self.rows(json.loads(self.request(port)[2]))[self.fixture.ids["needs"]]
        self.assertEqual([(p["label"], p["state"]) for p in row["prs"]], [("demo-repo#12", None), ("demo-repo#2", None)])
        self.assertTrue(all(PR_RE.match(p["url"]) for p in row["prs"]))
        self.gh_log.unlink()
        port = self.start("--no-gh")
        self.request(port)
        time.sleep(1)
        self.assertEqual(self.gh_calls(), [], "--no-gh never runs gh")

    def test_hanging_gh_never_blocks_the_page(self):
        port = self.start(mode="hang")
        for _ in range(3):
            started = time.time()
            status, _, _ = self.request(port)
            self.assertEqual(status, 200)
            self.assertLess(time.time() - started, 3)

    def test_bind_accepts_only_loopback(self):
        for bind in ("0.0.0.0", "192.168.1.10", "::", "example.com", "localhost", "127.0.0.1 ", "::ffff:127.0.0.1"):
            result = subprocess.run([RUBY, str(BOARD), "--bind", bind, "--port", "0", "--no-gh",
                                     "--state-dir", str(self.state)], env=ruby_env(self.webrick), text=True,
                                    capture_output=True, timeout=20)
            self.assertEqual(result.returncode, 2, bind)
            self.assertIn("--bind must be a loopback address", result.stderr)
            self.assertNotIn("Agent Board:", result.stdout)
        port = self.start("--no-gh", "--bind", "127.0.0.1")
        self.assertEqual(self.request(port)[0], 200)


class SnapshotGhTest(ServerBase):
    """The snapshot looks PR state up synchronously, through the same cache."""

    def test_snapshot_with_gh(self):
        env = dict(self.webrick, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}", FAKE_GH_LOG=str(self.gh_log))
        data = self.dump(env=env)
        row = self.rows(data)[self.fixture.ids["needs"]]
        self.assertEqual({p["label"]: p["state"] for p in row["prs"]},
                         {"demo-repo#12": "draft · CI pending · review requested", "demo-repo#2": "merged"})
        self.assertEqual(len(self.gh_calls()), 2, "one gh call per URL even though each is shown twice")


class DeployTest(unittest.TestCase):
    def test_recipe_deploys_board_and_installs_webrick(self):
        recipe = RECIPE.read_text(encoding="utf-8")
        files = re.search(r"%w\(([^)]*)\)\.each do \|file_name\|", recipe).group(1).split()
        self.assertIn("scripts/board.rb", files)
        self.assertIn("scripts/inbox.py", files)
        self.assertRegex(recipe, r"gem install[^\n]*webrick")

    @unittest.skipUnless(RUBY, "ruby is not on PATH")
    def test_webrick_install_follows_the_rbenv_node(self):
        stub = r"""
        Res = Struct.new(:attrs) do
          def method_missing(name, *args) = (attrs[name] = args.first)
          def respond_to_missing?(*) = true
        end
        class Graph
          attr_reader :rows
          def initialize(node) = (@node = node; @rows = [])
          def node = @node
          def agents_skill_link(*) = nil
          %i[directory remote_file execute].each do |kind|
            define_method(kind) { |name, &block| r = Res.new({}); r.instance_eval(&block); @rows << [kind, name, r.attrs] }
          end
        end
        setup = { home: "/h", user: "u", group: "g" }
        [{ setup: setup, rbenv: { root: "/h/.rbenv" } }, { setup: setup }].each do |node|
          g = Graph.new(node)
          g.instance_eval(File.read(ARGV[0]), ARGV[0])
          puts g.rows.select { |k, _, _| k == :execute }.map { |_, _, a| a[:command] }.inspect
        end
        """
        result = subprocess.run([RUBY, "-e", stub, str(RECIPE)], text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        with_rbenv, cloud = result.stdout.splitlines()
        self.assertEqual(json.loads(with_rbenv),
                         ["env RBENV_ROOT=/h/.rbenv /h/.rbenv/bin/rbenv exec gem install --no-document webrick"])
        self.assertEqual(json.loads(cloud), [], "the cloud entry has no rbenv and installs nothing")


if __name__ == "__main__":
    unittest.main()
