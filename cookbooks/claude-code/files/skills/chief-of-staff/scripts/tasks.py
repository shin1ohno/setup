#!/usr/bin/env python3
"""Private, atomic task ledger shared by Claude Code and Codex controllers."""

import argparse
import contextlib
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import stat
import subprocess
import sys
import tempfile
import uuid


TRANSITIONS = {
    "queued": {"needs-user", "cancelled"},
    "starting": {"running", "reviewing", "retry", "needs-user", "cancelled"},
    "running": {"reviewing", "retry", "needs-user", "cancelled"},
    "reviewing": {"accepted", "retry", "needs-user", "cancelled"},
    "retry": {"needs-user", "cancelled"},
    "needs-user": {"starting", "running", "reviewing", "retry", "cancelled"},
    "accepted": set(),
    "cancelled": set(),
}
TERMINAL = {"accepted", "cancelled"}
CLAUDE_ALIASES = {"opus", "sonnet", "haiku", "fable"}
TRANSCRIPT_LIMIT = 32 * 1024 * 1024
UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
SESSION_LOG = re.compile(UUID + r"\.jsonl")
ROLLOUT_LOG = re.compile(r"rollout-.+-(" + UUID + r")\.jsonl")


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def root_dir():
    return Path(os.environ.get(
        "COS_STATE_DIR", "~/.local/state/chief-of-staff"
    )).expanduser().resolve()


@contextlib.contextmanager
def locked(root):
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (root / ".lock").open("a", encoding="utf-8") as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def task_path(root, task_id):
    if not re.fullmatch(r"[a-f0-9]{16}", task_id):
        raise ValueError("invalid task ID")
    return root / task_id / "task.json"


def read_task(root, task_id):
    return json.loads(task_path(root, task_id).read_text(encoding="utf-8"))


def save_task(root, task):
    path = task_path(root, task["id"])
    path.parent.mkdir(mode=0o700, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".task-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(task, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def event(task, note, evidence=None):
    task["updated_at"] = now()
    task["history"].append({
        "at": task["updated_at"], "state": task["state"],
        "note": note, "evidence": evidence or [],
    })


def positive(value):
    value = int(value)
    if value < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return value


def nonempty(value):
    if not value.strip():
        raise argparse.ArgumentTypeError("must not be blank")
    return value


def parser():
    cli = argparse.ArgumentParser(description=__doc__)
    sub = cli.add_subparsers(dest="command", required=True)
    new = sub.add_parser("new", help="Record the original brief and criteria")
    for field in ("owner", "topic", "cwd", "scope"):
        new.add_argument("--" + field, required=True, type=nonempty)
    new.add_argument("--acceptance", action="append", required=True, type=nonempty)
    new.add_argument("--contract", choices=("legacy", "envelope-v1"), default="envelope-v1")
    new.add_argument("--max-attempts", type=positive, default=3)
    new.add_argument("--fresh-worker", action="store_true",
                     help="User requires a fresh agent and pane; prohibit worker reuse")
    ls = sub.add_parser("list", help="List only this controller's tasks")
    ls.add_argument("--owner", required=True, type=nonempty)
    ls.add_argument("--all", action="store_true", help="Include terminal tasks")
    sweep = sub.add_parser("closable", help="Read-only list of settled owned/orphan worker panes")
    sweep.add_argument("--owner", required=True, type=nonempty)
    sweep.add_argument("--herdr-session", required=True, type=nonempty)
    for name in ("show", "attempt", "bind", "update", "reported", "extend", "receive", "observe",
                 "check", "handoff", "criteria", "helper", "launch-command"):
        cmd = sub.add_parser(name)
        cmd.add_argument("task_id")
        cmd.add_argument("--owner", type=nonempty)
        if name == "launch-command":
            cmd.add_argument("--prompt", required=True, type=nonempty)
        elif name == "helper":
            cmd.add_argument("--pane", required=True, type=nonempty)
            cmd.add_argument("--terminal-id", required=True, type=nonempty)
            cmd.add_argument("--kind", choices=("claude", "codex", "shell"), required=True)
            cmd.add_argument("--agent-name", type=nonempty)
        elif name in {"handoff", "criteria"}:
            cmd.add_argument("--note", required=True, type=nonempty)
            if name == "handoff":
                cmd.add_argument("--to", required=True, type=nonempty)
            else:
                cmd.add_argument("--acceptance", action="append", required=True, type=nonempty)
        elif name == "attempt":
            cmd.add_argument("--kind", choices=("claude", "codex"), required=True)
            cmd.add_argument("--model", required=True, type=nonempty)
            cmd.add_argument("--reason", required=True, type=nonempty)
            cmd.add_argument("--effort", choices=("low", "medium", "high", "xhigh", "max", "ultra"))
            cmd.add_argument("--route", choices=("hc", "herdr1", "agent", "herdr"), default="herdr",
                             help="Launch route; herdr is a legacy unspecified terminal route")
            cmd.add_argument("--plan", type=nonempty,
                             help="Launch plan file used for this attempt; omit for default launches")
            cmd.add_argument("--profile", choices=("common", "dev", "cos", "writing"), required=True,
                             help="Worker instruction profile; recorded on the attempt")
            cmd.add_argument("--reuse-agent", action="store_true",
                             help="Reuse the previous settled worker's identity")
            cmd.add_argument("--launch-options", default=None,
                             help="JSON argv array of extra native CLI options; inherited on reuse")
        elif name == "bind":
            cmd.add_argument("--terminal-id", type=nonempty,
                             help="Herdr terminal_id from the creation/live response")
            cmd.add_argument("--rebind", action="store_true")
            cmd.add_argument("--evidence", action="append", type=nonempty, default=[])
            identity = cmd.add_mutually_exclusive_group(required=True)
            identity.add_argument("--pane", type=nonempty)
            identity.add_argument("--session", type=nonempty)
            cmd.add_argument("--model", type=nonempty)
            cmd.add_argument("--effort", type=nonempty)
        elif name == "receive":
            cmd.add_argument("--file", required=True, type=Path)
        elif name == "observe":
            cmd.add_argument("--transcript", required=True, type=Path,
                             help="Agent route: agent-<session>.jsonl; herdr route: the "
                                  "worker's Claude <session>.jsonl or Codex rollout-*.jsonl")
            cmd.add_argument("--launch-prompt", type=nonempty,
                             help="herdr route: the exact prompt the worker was launched with")
            cmd.add_argument("--remote-cwd", type=nonempty,
                             help="Exact absolute POSIX cwd in a fetched remote transcript; "
                                  "requires a machine-qualified herdr1 pane")
        elif name == "check":
            cmd.add_argument("--file", required=True, type=Path,
                             help="Saved output of the controller's independent check")
            cmd.add_argument("--exit-status", required=True, type=int)
            cmd.add_argument("--note", required=True, type=nonempty)
        elif name == "update":
            cmd.add_argument("--waived-by-owner", type=nonempty,
                             help="Owner decision waiving failed envelope criteria only")
            cmd.add_argument("--state", choices=TRANSITIONS, required=True)
            cmd.add_argument("--note", required=True, type=nonempty)
            cmd.add_argument("--evidence", action="append", type=nonempty, default=[])
            cmd.add_argument("--check", type=nonempty,
                             help="ID printed by an earlier `check` call (envelope-v1 accepted)")
        elif name in {"reported", "extend"}:
            cmd.add_argument("--note", required=True, type=nonempty)
            if name == "extend":
                cmd.add_argument("--max-attempts", required=True, type=positive)
    return cli


def envelope_bytes(path, roots):
    """Pin a contained regular file without blocking on FIFOs or following swaps."""
    if not path.is_absolute():
        raise ValueError("envelope must be inside the task or checkout")
    # Resolve legitimate contained symlinks once, then refuse symlinks during
    # descriptor traversal. A later replacement cannot redirect this read.
    resolved = path.resolve(strict=True)
    allowed = next((root for root in roots if resolved.is_relative_to(root)), None)
    if allowed is None:
        raise ValueError("envelope must be inside the task or checkout")
    descriptors = []
    try:
        directory = os.open(resolved.anchor, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        descriptors.append(directory)
        parts = resolved.parts[1:]
        if not parts:
            raise ValueError("envelope must be a regular file")
        for part in parts[:-1]:
            directory = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW |
                                os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory)
            descriptors.append(directory)
        if not stat.S_ISREG(os.stat(parts[-1], dir_fd=directory, follow_symlinks=False).st_mode):
            raise ValueError("envelope must be a regular file")
        descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK |
                             os.O_CLOEXEC | os.O_NOCTTY, dir_fd=directory)
        descriptors.append(descriptor)
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("envelope must be a regular file")
        if info.st_size > 16384:
            raise ValueError("envelope exceeds 16 KiB")
        data = os.read(descriptor, 16385)
        if len(data) > 16384:
            raise ValueError("envelope exceeds 16 KiB")
        return data
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def model_matches(requested, observed):
    """A Claude alias matches the full model ID the harness reports for it."""
    if not requested or not observed:
        return False
    if requested == observed:
        return True
    return requested in CLAUDE_ALIASES and observed.startswith("claude-" + requested + "-")


def read_log(path):
    """Read a worker log as JSON records without following links or blocking."""
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    descriptor = os.open(path, flags)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("transcript must be a regular file")
        if info.st_size > TRANSCRIPT_LIMIT:
            raise ValueError("transcript is too large")
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            data = handle.read(TRANSCRIPT_LIMIT + 1)
    finally:
        os.close(descriptor)
    records = []
    # JSONL records end at LF; Unicode separators can occur inside JSON strings.
    for line in data.decode("utf-8").split("\n"):
        if line.strip():
            record = json.loads(line)
            if isinstance(record, dict):
                records.append(record)
    return records


def text(value):
    return value if isinstance(value, str) and value else None


def log_time(record):
    try:
        moment = datetime.fromisoformat(record["timestamp"])
    except (KeyError, TypeError, ValueError):
        raise ValueError("a counted log entry lacks a valid timestamp") from None
    if moment.tzinfo is None:
        raise ValueError("a counted log entry has a timestamp without a time zone")
    return moment


def inside(value, directory):
    return isinstance(value, str) and Path(value).is_absolute() and \
        Path(value).resolve().is_relative_to(directory)


def blocks_text(content):
    """Text of a message whose content is a string or a list of text blocks."""
    if isinstance(content, str):
        return content
    if isinstance(content, list) and all(isinstance(b, dict) for b in content) and \
            {b.get("type") for b in content} <= {"text", "input_text"}:
        return "".join(b.get("text", "") for b in content)
    return None


def require_launch_prompt(first, prompt):
    """The worker's log opens with the prompt the controller launched it with.

    cwd and time window cannot tell a worker from a controller that shares its
    directory; the controller's own first message is never the launch prompt."""
    if first is None:
        raise ValueError("the log records no first user message")
    if first.strip() != prompt.strip():
        raise ValueError("the log's first user message is not this attempt's launch prompt")


def agent_pairs(path, session):
    """(model, effort) of every assistant turn in an Agent-tool transcript."""
    if path.name != "agent-" + session + ".jsonl":
        raise ValueError("transcript name does not match the bound session")
    pairs = []
    for record in read_log(path):
        if record.get("type") != "assistant":
            continue
        message = record.get("message")
        model = text(message.get("model")) if isinstance(message, dict) else None
        pairs.append((model, text(record.get("effort"))))
    return pairs


def transcript_cwd_matches(value, cwd, remote_cwd):
    # Remote paths belong to another filesystem: never resolve them locally.
    return value == remote_cwd if remote_cwd is not None else inside(value, cwd)


def claude_pairs(path, cwd, since, prompt, remote_cwd=None):
    """(model, effort) of the worker's own assistant turns since the attempt began.

    Harness-inserted `<synthetic>` turns and sidechain (subagent) turns are
    not the worker's effective selection and are skipped."""
    if not SESSION_LOG.fullmatch(path.name):
        raise ValueError("Claude session log must be named <session-uuid>.jsonl")
    session = path.name[:-len(".jsonl")]
    started, pairs, first = False, [], None
    for record in read_log(path):
        if record.get("sessionId", session) != session:
            raise ValueError("a log entry belongs to another session")
        if not started and "cwd" in record:
            if not transcript_cwd_matches(record["cwd"], cwd, remote_cwd):
                raise ValueError("the session did not start inside the task directory")
            started = True
        if record.get("type") == "user" and first is None and record.get("isMeta") is not True \
                and record.get("isSidechain") is not True:
            message = record.get("message")
            first = blocks_text(message.get("content")) if isinstance(message, dict) else None
            first = "" if first is None else first
        if record.get("type") != "assistant" or record.get("isSidechain") is True:
            continue
        message = record.get("message")
        model = text(message.get("model")) if isinstance(message, dict) else None
        if model == "<synthetic>" or log_time(record) < since:
            continue
        pairs.append((model, text(record.get("effort"))))
    if not started:
        raise ValueError("the log records no working directory")
    require_launch_prompt(first, prompt)
    return pairs, session


def codex_pairs(path, cwd, since, prompt, remote_cwd=None):
    """(model, effort) of every Codex turn_context since the attempt began."""
    match = ROLLOUT_LOG.fullmatch(path.name)
    if not match:
        raise ValueError("Codex log must be named rollout-<time>-<session-uuid>.jsonl")
    records = read_log(path)
    meta = records[0].get("payload") if records and records[0].get("type") == "session_meta" else None
    if not isinstance(meta, dict) or meta.get("id") != match.group(1):
        raise ValueError("the rollout does not open with this session's session_meta")
    if not transcript_cwd_matches(meta.get("cwd"), cwd, remote_cwd):
        raise ValueError("the session did not start inside the task directory")
    first = None
    for record in records:
        payload = record.get("payload")
        item = payload.get("item") if isinstance(payload, dict) else None
        if isinstance(item, dict) and record.get("type") == "event_msg" \
                and payload.get("type") == "item_completed" and item.get("type") == "UserMessage":
            first = blocks_text(item.get("content")) or ""
            break
    require_launch_prompt(first, prompt)
    pairs = []
    for record in records:
        if record.get("type") != "turn_context" or log_time(record) < since:
            continue
        payload = record.get("payload")
        payload = payload if isinstance(payload, dict) else {}
        pairs.append((text(payload.get("model")), text(payload.get("effort"))))
    return pairs, match.group(1)


def single_pair(pairs):
    """Return the one (model, effort) pair, or the reason the log cannot give one."""
    if not pairs:
        return None, "the log records no model/effort for this attempt"
    if any(model is None or effort is None for model, effort in pairs):
        return None, "a counted turn lacks its model or effort"
    distinct = sorted(set(pairs))
    if len(distinct) != 1:
        return None, "the log records mixed model/effort pairs: " + \
            ", ".join(m + " / " + e for m, e in distinct)
    return distinct[0], None


def check_file(path, task, root):
    """Hash a contained regular evidence file so later edits are detectable."""
    roots = [Path(task["cwd"]).resolve(), task_path(root, task["id"]).parent.resolve()]
    if not path.is_absolute():
        raise ValueError("check file must be an absolute path")
    resolved = path.resolve(strict=True)
    if not any(resolved.is_relative_to(r) for r in roots):
        raise ValueError("check file must be inside the task or checkout")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    descriptor = os.open(resolved, flags)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ValueError("check file must be a regular file")
        digest = hashlib.sha256()
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            for block in iter(lambda: handle.read(65536), b""):
                digest.update(block)
    finally:
        os.close(descriptor)
    return str(resolved), digest.hexdigest()


def require_passing_check(attempt, check_id, receipt):
    """envelope-v1 acceptance cites the latest check recorded by an earlier call."""
    checks = attempt.get("checks") or []
    if not checks:
        raise ValueError("acceptance requires a check recorded for this attempt; run `check` first")
    latest = checks[-1]
    if not receipt or latest.get("envelope_receipt") != receipt:
        raise ValueError("record a check after receiving the current envelope")
    if latest["exit_status"] != 0:
        raise ValueError("the latest recorded check failed (exit " +
                         str(latest["exit_status"]) + "); fix and record a new check")
    if check_id != latest["id"]:
        raise ValueError("pass --check with the ID printed by the latest `check` call")


def read_envelope(path, task, root):
    """Validate structure and evidence locations; never claim artifact quality."""
    roots = [Path(task["cwd"]).resolve(), task_path(root, task["id"]).parent.resolve()]
    data = envelope_bytes(path, roots)
    digest = hashlib.sha256(data).hexdigest()
    if digest in task["attempts"][-1].get("invalidated_envelope_sha256", []):
        raise ValueError("envelope was invalidated by rebind; require a freshly written envelope")
    envelope = json.loads(data.decode("utf-8"))
    # Pre-hash ledgers retain the parsed envelope in rebind history.
    if any(h.get("previous_envelope") == envelope for h in task["history"] if "rebind" in h):
        raise ValueError("envelope was invalidated by rebind; require a freshly written envelope")
    expected = {"task_id", "attempt", "status", "summary", "artifacts", "criteria", "open_questions"}
    if not isinstance(envelope, dict) or set(envelope) != expected:
        raise ValueError("invalid envelope fields")
    if (envelope["task_id"] != task["id"] or type(envelope["attempt"]) is not int
            or envelope["attempt"] != len(task["attempts"])):
        raise ValueError("stale or foreign envelope")
    if envelope["status"] not in {"done", "blocked", "failed"}:
        raise ValueError("invalid envelope status")
    if not isinstance(envelope["summary"], str) or len(envelope["summary"].encode("utf-8")) > 1200:
        raise ValueError("summary exceeds 1200 bytes")
    def artifact(value):
        if not isinstance(value, str) or len(value) > 4096:
            raise ValueError("invalid evidence path")
        p = Path(value)
        if not p.is_absolute() or not p.is_file() or not any(p.resolve().is_relative_to(r) for r in roots):
            raise ValueError(f"artifact must be a regular file inside the task or checkout: {value}")
    if not isinstance(envelope["artifacts"], list):
        raise ValueError("artifacts must be a list")
    if len(envelope["artifacts"]) > 12:
        raise ValueError(f"artifact limit is 12; received {len(envelope['artifacts'])}")
    for value in envelope["artifacts"]:
        artifact(value)
    criteria = envelope["criteria"]
    if not isinstance(criteria, list) or len(criteria) != len(task["acceptance"]):
        raise ValueError("criteria must cover the original acceptance list")
    names = []
    for item in criteria:
        if not isinstance(item, dict) or set(item) != {"criterion", "status", "evidence"}:
            raise ValueError("invalid criterion fields")
        names.append(item["criterion"])
        if item["status"] not in {"pass", "fail", "unverified"}:
            raise ValueError("invalid criterion status")
        artifact(item["evidence"])
    if sorted(names) != sorted(task["acceptance"]):
        raise ValueError("criteria changed or duplicated")
    if envelope["status"] == "done" and any(c["status"] != "pass" for c in criteria):
        raise ValueError("done with a failed or unverified criterion is not complete")
    questions = envelope["open_questions"]
    if not isinstance(questions, list) or len(questions) > 8 or any(not isinstance(q, str) or len(q.encode("utf-8")) > 600 for q in questions):
        raise ValueError("invalid open questions")
    return envelope, digest


def closable(args, root):
    """Fail closed; no close operation is performed by this command."""
    socket, separator, caller = args.owner.rpartition("#")
    pane_pattern = r"w[^:#\s]+:p[^:#\s]+"
    if not separator or not socket.startswith("/") or not re.fullmatch(pane_pattern, caller):
        raise ValueError("closable requires a verified local Herdr socket#pane owner")
    def herdr(*argv):
        result = subprocess.run(["herdr", "--session", args.herdr_session, *argv],
                                capture_output=True, text=True, timeout=10, check=True)
        return result.stdout
    status = herdr("status", "server")
    if ("socket: " + socket) not in status.splitlines():
        raise ValueError("Herdr session does not resolve to the owner's socket")
    workspaces = json.loads(herdr("workspace", "list"))["result"]["workspaces"]
    panes = {}
    for workspace in workspaces:
        for pane in json.loads(herdr("pane", "list", "--workspace", workspace["workspace_id"]))["result"]["panes"]:
            if pane["pane_id"] in panes:
                raise ValueError("ambiguous pane inventory")
            panes[pane["pane_id"]] = pane
    if caller not in panes:
        raise ValueError("verified controller pane is absent")
    tasks = [json.loads(p.read_text()) for p in sorted(root.glob("*/task.json"))]
    controllers = {t.get("owner", "").rpartition("#")[2] for t in tasks
                   if t.get("owner", "").rpartition("#")[0] == socket}
    bindings = {}
    for task in tasks:
        if task.get("owner", "").rpartition("#")[0] != socket:
            continue
        for attempt in task.get("attempts", []):
            for record in [attempt, *attempt.get("helpers", [])]:
                if record.get("pane"):
                    bindings.setdefault(record["pane"], []).append((task, attempt, record))
    candidates = []
    for pane_id, references in bindings.items():
        # Multiple task/attempt claims cannot prove which process is current.
        if len(references) != 1 or pane_id in controllers or pane_id == caller:
            continue
        task, attempt, record = references[0]
        owner = task["owner"]
        if not re.fullmatch(pane_pattern, owner.rpartition("#")[2]):
            continue
        if owner != args.owner and owner.rpartition("#")[2] in panes:
            continue
        if task.get("state") not in {"reviewing", "needs-user", "accepted", "cancelled"}:
            continue
        if attempt.get("route", "herdr") not in {"herdr", "herdr1"}:
            continue
        if task["state"] == "reviewing" and not task.get("envelope_receipt"):
            continue
        if (not model_matches(attempt.get("requested_model", attempt.get("model")),
                              attempt.get("observed_model"))
                or not attempt.get("effort") or attempt.get("observed_effort") != attempt["effort"]):
            continue
        pane = panes.get(pane_id, {})
        if (not record.get("terminal_id") or pane.get("terminal_id") != record["terminal_id"]
                or pane.get("agent_status") not in {"idle", "done"}
                or pane.get("agent") != record.get("kind")):
            continue
        agent = json.loads(herdr("agent", "get", pane_id))["result"]["agent"]
        if (not record.get("agent") or agent.get("name") != record["agent"]
                or agent.get("terminal_id") != record["terminal_id"]
                or agent.get("agent") != record.get("kind")
                or agent.get("agent_status") not in {"idle", "done"}):
            continue
        candidates.append({"task_id": task["id"], "attempt": attempt["number"],
                           "pane": pane_id, "terminal_id": record["terminal_id"],
                           "owner": owner, "reason": "own" if owner == args.owner else "orphan"})
    return {"candidates": candidates, "read_only": True,
            "note": "Recheck owner, terminal identity and idle/done immediately before closing."}


def run(args, root):
    if args.command == "closable":
        return closable(args, root)
    if args.command == "new":
        cwd = Path(args.cwd).expanduser()
        if not cwd.is_absolute() or not cwd.is_dir():
            raise ValueError("cwd must be an existing absolute directory")
        task_id = uuid.uuid4().hex[:16]
        task = {
            "id": task_id, "owner": args.owner, "topic": args.topic,
            "cwd": str(cwd.resolve()), "scope": args.scope,
            "acceptance": args.acceptance, "state": "queued",
            "max_attempts": args.max_attempts, "attempts": [], "history": [],
            "fresh_worker": args.fresh_worker, "contract": args.contract,
            "created_at": now(), "last_report": None, "report_pending": False,
        }
        event(task, "Task created")
        save_task(root, task)
        return {"task": task, "directory": str(task_path(root, task_id).parent)}
    if args.command == "list":
        tasks = [json.loads(path.read_text(encoding="utf-8"))
                 for path in sorted(root.glob("*/task.json"))]
        return {"tasks": [task for task in tasks if task["owner"] == args.owner
                          and (args.all or task["state"] not in TERMINAL
                               or task.get("report_pending", True))]}

    task = read_task(root, args.task_id)
    result = {}
    strict = task.get("contract") == "envelope-v1"
    if (args.owner and args.owner != task["owner"]) or (strict and args.command != "show" and not args.owner):
        raise ValueError("mutation requires this task's verified controller owner")
    if args.command == "show":
        return {"task": task}
    if args.command == "launch-command":
        attempt = task["attempts"][-1]
        plan = attempt.get("launch_plan")
        if not plan or not plan.get("launch_ready") or plan.get("harness") != attempt["kind"]:
            raise ValueError("launch-command requires a recorded ready profile plan")
        argv = list(plan["argv"])
        if attempt.get("reuse"):
            session = attempt.get("resume_session")
            if not session or not re.fullmatch(UUID, session):
                raise ValueError("resume requires an observed session UUID")
            argv[1:1] = ["--resume", session] if attempt["kind"] == "claude" else ["resume", session]
        argv += [args.prompt, *attempt.get("launch_options", [])]
        env = ["env"]
        for key in plan["env_unset"]:
            env += ["-u", key]
        env += [key + "=" + value for key, value in plan["env_set"].items()]
        return {"argv": argv, "env_set": plan["env_set"], "env_unset": plan["env_unset"],
                "command": shlex.join(env + argv), "cwd": task["cwd"]}
    if args.command in {"handoff", "criteria"}:
        if not args.owner:
            raise ValueError("mutation requires this task's verified controller owner")
        if args.command == "handoff":
            old_owner = task["owner"]
            task["owner"] = args.to
            event(task, "Owner handoff: " + args.note)
            task["history"][-1]["handoff"] = {"from": old_owner, "to": args.to}
        else:
            if task["state"] in TERMINAL:
                raise ValueError("cannot change criteria of a completed task")
            previous = {"acceptance": task["acceptance"],
                        "envelope": task.pop("envelope", None), "checks": []}
            if task["attempts"]:
                previous["checks"] = task["attempts"][-1].pop("checks", [])
                task["attempts"][-1]["ended_at"] = now()
                task["state"] = "retry"
            previous["envelope_receipt"] = task.pop("envelope_receipt", None)
            previous["envelope_sha256"] = task.pop("envelope_sha256", None)
            task["acceptance"] = args.acceptance
            event(task, "Owner criteria change: " + args.note)
            task["history"][-1]["criteria_change"] = {
                "previous": previous, "acceptance": args.acceptance,
                "attempt": len(task["attempts"])}
    elif args.command == "helper":
        if not args.owner:
            raise ValueError("helper registration requires the controller owner")
        if not task.get("attempts") or task["state"] in TERMINAL:
            raise ValueError("helper requires an unfinished attempt")
        attempt = task["attempts"][-1]
        if args.kind != "shell" and not args.agent_name:
            raise ValueError("agent helpers require their live agent name")
        if args.pane == task["owner"].rpartition("#")[2] or args.pane == attempt.get("pane"):
            raise ValueError("helper cannot be the controller or worker")
        helpers = attempt.setdefault("helpers", [])
        if any(h["pane"] == args.pane for h in helpers):
            raise ValueError("helper already recorded")
        helpers.append({"pane": args.pane, "terminal_id": args.terminal_id, "kind": args.kind,
                        "agent": args.agent_name})
        event(task, "Registered helper " + args.pane)
    elif args.command == "attempt":
        if task["state"] not in {"queued", "retry", "needs-user"}:
            raise ValueError("reconcile the existing attempt before reserving another")
        if len(task["attempts"]) >= task["max_attempts"]:
            raise ValueError("attempt budget exhausted; explicit user extension required")
        if strict and (args.model == "default" or not args.effort):
            raise ValueError("choose an explicit model and effort before dispatch")
        previous = task["attempts"][-1] if task["attempts"] else None
        if args.reuse_agent and task.get("fresh_worker"):
            raise ValueError("user requires a fresh worker; agent reuse is forbidden")
        if args.reuse_agent and (previous is None or previous["kind"] != args.kind
                                 or previous.get("requested_model", previous["model"]) != args.model
                                 or previous.get("effort") != args.effort
                                 or previous.get("route", "herdr") != args.route):
            raise ValueError("reuse requires the previous worker's same kind, model, effort and route "
                             f"(previous route: {previous.get('route', 'herdr') if previous else 'none'}; "
                             f"requested route: {args.route})")
        plan = args.plan
        options = json.loads(args.launch_options) if args.launch_options is not None else []
        if not isinstance(options, list) or not all(isinstance(item, str) for item in options):
            raise ValueError("launch-options must be a JSON string array")
        if args.reuse_agent:
            if plan is not None and plan != previous.get("plan"):
                raise ValueError("reuse cannot change the previous worker's launch plan")
            plan = previous.get("plan")
            if args.launch_options is not None and options != previous.get("launch_options", []):
                raise ValueError("reuse cannot change launch options")
            options = previous.get("launch_options", [])
        if args.plan is not None:
            path = Path(plan)
            if not path.is_absolute() or not path.is_file():
                raise ValueError("plan must be an absolute path to an existing file")
            launch = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(launch, dict) or launch.get("route") != args.route:
                raise ValueError("plan route must match the attempt route")
        attempt = {
            "number": len(task["attempts"]) + 1,
            "agent": "cos-" + task["id"] + "-" + str(len(task["attempts"]) + 1),
            "kind": args.kind, "model": args.model, "reason": args.reason,
            "requested_model": args.model, "effort": args.effort,
            "observed_model": None, "observed_effort": None,
            "route": args.route, "plan": plan, "profile": args.profile, "session": None,
            "pane": None, "created_at": now(),
            "reuse": args.reuse_agent,
            "launch_options": options,
        }
        if args.reuse_agent:
            attempt["agent"] = previous["agent"]
            if previous.get("profile") != args.profile:
                raise ValueError("reuse cannot change the worker profile")
            attempt["resume_session"] = (previous.get("observed_session")
                if model_matches(args.model, previous.get("observed_model"))
                and previous.get("observed_effort") == args.effort else None)
            attempt["launch_prompt"] = previous.get("launch_prompt")
            attempt["launch_plan"] = previous.get("launch_plan")
        elif args.plan is not None:
            attempt["launch_plan"] = launch
        task.pop("envelope", None)
        task.pop("envelope_receipt", None)
        task.pop("envelope_sha256", None)
        task["attempts"].append(attempt)
        task["state"] = "starting"
        event(task, args.reason)
        result["attempt"] = attempt
    elif args.command == "bind":
        if task["state"] not in {"starting", "running", "reviewing"}:
            raise ValueError("bind requires a live attempt")
        attempt = task["attempts"][-1]
        if (attempt.get("route", "herdr") != "agent") != bool(args.pane):
            raise ValueError("bind the identity returned by the selected route")
        if (args.model or args.effort) and strict:
            raise ValueError("bind cannot record model or effort for any envelope-v1 attempt; "
                             "run observe --transcript <session-log> (with --launch-prompt on terminal routes) instead")
        if args.rebind and (not args.pane or not args.evidence or not args.owner):
            raise ValueError("--rebind requires --pane, --owner and --evidence")
        if args.rebind and args.pane and (attempt.get("pane") is None or attempt["pane"] == args.pane):
            raise ValueError("--rebind requires a change from an already bound pane")
        if args.session:
            if attempt.get("session") not in (None, args.session):
                raise ValueError("session already bound")
            attempt["session"] = args.session
        if args.pane and task.get("fresh_worker") and attempt["pane"] != args.pane:
            socket, _, controller = task["owner"].rpartition("#")
            if args.pane == controller:
                raise ValueError("fresh worker cannot use the controller pane")
            for path in root.glob("*/task.json"):
                other = json.loads(path.read_text(encoding="utf-8"))
                owners = {other["owner"]}
                owners.update(h["handoff"][key] for h in other["history"]
                              if "handoff" in h for key in ("from", "to"))
                if socket in {owner.rpartition("#")[0] for owner in owners}:
                    historical_panes = {h["rebind"]["from"] for h in other["history"]
                                        if "rebind" in h}
                    if (args.pane in historical_panes or
                            any(a.get("pane") == args.pane for a in other["attempts"])):
                        raise ValueError("fresh worker cannot use a previously bound pane")
        if args.pane and attempt["pane"] is not None and attempt["pane"] != args.pane:
            if not args.rebind:
                raise ValueError("pane already bound; use --rebind with evidence")
            event(task, "Rebound worker pane", args.evidence)
            task["history"][-1]["rebind"] = {"from": attempt["pane"], "to": args.pane}
            # The new process must be observed and reviewed independently.
            task["history"][-1]["previous_observation"] = {
                key: attempt.pop(key, None) for key in
                ("observed_model", "observed_effort", "observed_source", "observed_session")}
            task["history"][-1]["previous_checks"] = attempt.pop("checks", [])
            task["history"][-1]["previous_envelope"] = task.pop("envelope", None)
            task["history"][-1]["previous_envelope_sha256"] = task.pop("envelope_sha256", None)
            task["history"][-1]["previous_envelope_receipt"] = task.pop("envelope_receipt", None)
            invalidated = attempt.setdefault("invalidated_envelope_sha256", [])
            invalidated.extend(h["envelope_sha256"] for h in task["history"]
                               if h.get("attempt") == attempt["number"] and h.get("envelope_sha256")
                               and h["envelope_sha256"] not in invalidated)
        if args.pane:
            attempt["pane"] = args.pane
            attempt["terminal_id"] = args.terminal_id
        if args.model:
            attempt["model"] = args.model
            attempt["observed_model"] = args.model
        if args.effort:
            attempt["observed_effort"] = args.effort
        event(task, "Bound worker " + (args.pane or args.session))
    elif args.command == "observe":
        if task["state"] not in {"starting", "running", "reviewing"}:
            raise ValueError("observe requires a live attempt")
        attempt = task["attempts"][-1]
        if args.remote_cwd is not None or attempt.get("observed_remote_cwd") is not None:
            # A failed remote re-observation must not leave a usable old proof.
            attempt["observed_model"] = attempt["observed_effort"] = None
            attempt["observed_remote_cwd"] = None
            save_task(root, task)
        if args.remote_cwd is not None:
            remote = PurePosixPath(args.remote_cwd)
            if (not remote.is_absolute() or ".." in remote.parts
                    or str(remote) != args.remote_cwd or str(remote) == "/"):
                raise ValueError("remote cwd must be a normalized absolute POSIX directory")
            if (attempt.get("route") != "herdr1"
                    or not re.fullmatch(r"machine:[^#\s]+#[^#\s]+", attempt.get("pane") or "")):
                raise ValueError("remote cwd requires a machine-qualified herdr1 pane")
        if (attempt.get("route") == "agent") == bool(args.launch_prompt):
            raise ValueError("--launch-prompt is required on the herdr route and only there")
        if attempt.get("route") == "agent":
            if not attempt.get("session"):
                raise ValueError("observe reads Agent-tool transcripts; bind the session first")
            pairs, session = agent_pairs(args.transcript, attempt["session"]), attempt["session"]
        else:
            if not attempt.get("pane"):
                raise ValueError("bind the worker pane or terminal before observing its log")
            reader = claude_pairs if attempt["kind"] == "claude" else codex_pairs
            pairs, session = reader(args.transcript, Path(task["cwd"]).resolve(),
                                    datetime.fromisoformat(attempt["created_at"]),
                                    args.launch_prompt, remote_cwd=args.remote_cwd)
        pair, refusal = single_pair(pairs)
        if attempt.get("resume_session") and attempt["resume_session"] != session:
            refusal = "resumed worker must retain the recorded session identity"
        if any(h.get("previous_observation", {}).get("observed_session") == session
               for h in task["history"] if "rebind" in h):
            refusal = "session was invalidated by rebind; observe the replacement worker"
        attempt["observed_source"] = str(args.transcript)
        attempt["observed_session"] = session
        attempt["launch_prompt"] = args.launch_prompt
        if refusal:
            # A refused log clears earlier values so `accepted` cannot rest on them.
            attempt["observed_model"] = attempt["observed_effort"] = None
            event(task, "Observation refused: " + refusal, [str(args.transcript)])
            save_task(root, task)
            raise ValueError(refusal)
        model, effort = pair
        attempt["observed_model"] = model
        attempt["observed_effort"] = effort
        if args.remote_cwd is not None:
            attempt["observed_remote_cwd"] = args.remote_cwd
        event(task, "Observed " + model + " / " + effort + " in the worker log",
              [str(args.transcript)])
        result["observed"] = {"model": model, "effort": effort}
    elif args.command == "receive":
        if task["state"] not in {"running", "reviewing"}:
            raise ValueError("receive requires a running or reviewing attempt")
        try:
            envelope, digest = read_envelope(args.file, task, root)
        except (ValueError, OSError, KeyError, TypeError) as error:
            event(task, "Receive refused: " + str(error), [str(args.file)])
            task["history"][-1]["previous_envelope"] = task.pop("envelope", None)
            task["history"][-1]["previous_envelope_receipt"] = task.pop("envelope_receipt", None)
            task["history"][-1]["previous_envelope_sha256"] = task.pop("envelope_sha256", None)
            task["history"][-1]["previous_checks"] = task["attempts"][-1].pop("checks", [])
            save_task(root, task)
            raise
        task["envelope"] = envelope
        task["envelope_sha256"] = digest
        task["envelope_receipt"] = uuid.uuid4().hex
        task["state"] = "reviewing"
        event(task, "Received bounded envelope", [str(args.file)])
        task["history"][-1].update(
            envelope_sha256=digest, envelope_receipt=task["envelope_receipt"],
            attempt=len(task["attempts"]),
            previous_checks=task["attempts"][-1].pop("checks", []))
        save_task(root, task)
        return {"task_id": task["id"], "state": task["state"], "envelope": envelope}
    elif args.command == "check":
        if task["state"] not in {"running", "reviewing"}:
            raise ValueError("check requires a running or reviewing attempt")
        attempt = task["attempts"][-1]
        path, digest = check_file(args.file, task, root)
        record = {
            "id": uuid.uuid4().hex[:12], "at": now(), "file": path, "sha256": digest,
            "exit_status": args.exit_status, "passed": args.exit_status == 0,
            "note": args.note, "envelope_receipt": task.get("envelope_receipt"),
        }
        attempt.setdefault("checks", []).append(record)
        event(task, "Recorded check " + record["id"] + " exit " + str(args.exit_status) +
              ": " + args.note, [path])
        result["check"] = record
    elif args.command == "update":
        if args.waived_by_owner and (args.state != "accepted" or not args.owner):
            raise ValueError("--waived-by-owner requires accepted and --owner")
        if args.check and args.state != "accepted":
            raise ValueError("--check applies only to accepted")
        if args.state not in TRANSITIONS[task["state"]]:
            raise ValueError("invalid transition: " + task["state"] + " -> " + args.state)
        if args.state in {"starting", "running", "reviewing", "accepted", "retry"} and not args.evidence:
            raise ValueError("this transition requires observed evidence")
        if (task["attempts"] and task["attempts"][-1].get("ended_at")
                and args.state in {"starting", "running", "reviewing", "accepted"}):
            raise ValueError("criteria ended this attempt; reserve a new attempt")
        if args.state == "starting" and not task["attempts"]:
            raise ValueError("reserve an attempt before resuming startup")
        if args.state in {"running", "reviewing", "accepted"}:
            if not task["attempts"] or not (task["attempts"][-1].get("pane") or task["attempts"][-1].get("session")):
                raise ValueError("bind the observed pane before recording execution")
        if args.waived_by_owner or (strict and args.state == "accepted"):
            envelope = task.get("envelope", {})
            if not envelope:
                raise ValueError("acceptance requires a received envelope")
            if (args.waived_by_owner and envelope.get("status") == "done"
                    and all(c["status"] == "pass" for c in envelope.get("criteria", []))):
                raise ValueError("a complete passing envelope does not need an owner waiver")
        if strict and args.state == "accepted":
            if not args.waived_by_owner and (envelope.get("status") != "done" or not all(
                    c["status"] == "pass" for c in envelope.get("criteria", []))):
                raise ValueError("acceptance requires a complete passing envelope and independent review")
            attempt = task["attempts"][-1]
            if (not model_matches(attempt.get("requested_model"), attempt.get("observed_model"))
                    or attempt.get("observed_effort") != attempt.get("effort")):
                raise ValueError("effective model/effort has not been observed to match the request")
            require_passing_check(attempt, args.check, task.get("envelope_receipt"))
        task["state"] = args.state
        if args.state == "retry" and len(task["attempts"]) >= task["max_attempts"]:
            task["state"] = "needs-user"
        if task["state"] in TERMINAL or task["state"] == "needs-user":
            task["report_pending"] = True
        event(task, args.note, args.evidence)
        if args.waived_by_owner:
            task["history"][-1]["owner_waiver"] = {
                "owner": args.owner, "reason": args.waived_by_owner,
                "acceptance": task["acceptance"], "envelope": task.get("envelope")}
    elif args.command == "reported":
        task["last_report"] = {"at": now(), "note": args.note}
        task["report_pending"] = False
        event(task, "Reported to user: " + args.note)
    elif args.command == "extend":
        if task["state"] in TERMINAL:
            raise ValueError("cannot extend a completed task")
        if args.max_attempts <= task["max_attempts"]:
            raise ValueError("extension must increase the existing budget")
        task["max_attempts"] = args.max_attempts
        event(task, "User budget extension: " + args.note)
    save_task(root, task)
    result["task"] = task
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        root = root_dir()
        with locked(root):
            result = run(args, root)
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
