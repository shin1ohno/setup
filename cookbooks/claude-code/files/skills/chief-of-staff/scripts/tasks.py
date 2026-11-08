#!/usr/bin/env python3
"""Private, atomic task ledger shared by Claude Code and Codex controllers."""

import argparse
import contextlib
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
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
    for name in ("show", "attempt", "bind", "update", "reported", "extend", "receive", "observe",
                 "check"):
        cmd = sub.add_parser(name)
        cmd.add_argument("task_id")
        cmd.add_argument("--owner", type=nonempty)
        if name == "attempt":
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
        elif name == "bind":
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
        elif name == "check":
            cmd.add_argument("--file", required=True, type=Path,
                             help="Saved output of the controller's independent check")
            cmd.add_argument("--exit-status", required=True, type=int)
            cmd.add_argument("--note", required=True, type=nonempty)
        elif name == "update":
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
    for line in data.decode("utf-8").splitlines():
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


def claude_pairs(path, cwd, since, prompt):
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
            if not inside(record["cwd"], cwd):
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


def codex_pairs(path, cwd, since, prompt):
    """(model, effort) of every Codex turn_context since the attempt began."""
    match = ROLLOUT_LOG.fullmatch(path.name)
    if not match:
        raise ValueError("Codex log must be named rollout-<time>-<session-uuid>.jsonl")
    records = read_log(path)
    meta = records[0].get("payload") if records and records[0].get("type") == "session_meta" else None
    if not isinstance(meta, dict) or meta.get("id") != match.group(1):
        raise ValueError("the rollout does not open with this session's session_meta")
    if not inside(meta.get("cwd"), cwd):
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


def require_passing_check(attempt, check_id):
    """envelope-v1 acceptance cites the latest check recorded by an earlier call."""
    checks = attempt.get("checks") or []
    if not checks:
        raise ValueError("acceptance requires a check recorded for this attempt; run `check` first")
    latest = checks[-1]
    if latest["exit_status"] != 0:
        raise ValueError("the latest recorded check failed (exit " +
                         str(latest["exit_status"]) + "); fix and record a new check")
    if check_id != latest["id"]:
        raise ValueError("pass --check with the ID printed by the latest `check` call")


def read_envelope(path, task, root):
    """Validate structure and evidence locations; never claim artifact quality."""
    roots = [Path(task["cwd"]).resolve(), task_path(root, task["id"]).parent.resolve()]
    data = envelope_bytes(path, roots)
    envelope = json.loads(data.decode("utf-8"))
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
            raise ValueError("artifact must be a file inside the task or checkout")
    if not isinstance(envelope["artifacts"], list) or len(envelope["artifacts"]) > 12:
        raise ValueError("invalid artifact list")
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
    return envelope


def run(args, root):
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
    if args.command == "attempt":
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
        if args.reuse_agent:
            if plan is not None and plan != previous.get("plan"):
                raise ValueError("reuse cannot change the previous worker's launch plan")
            plan = previous.get("plan")
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
        }
        if args.reuse_agent:
            attempt["agent"] = previous["agent"]
        task.pop("envelope", None)
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
        if (args.model or args.effort) and task.get("contract") == "envelope-v1" \
                and attempt.get("route", "herdr") != "agent":
            raise ValueError("bind cannot record model or effort for an envelope-v1 herdr attempt; "
                             "run observe --transcript <session-log> --launch-prompt <prompt> instead")
        if args.session:
            if attempt.get("session") not in (None, args.session):
                raise ValueError("session already bound")
            attempt["session"] = args.session
        if args.pane and task.get("fresh_worker") and attempt["pane"] is None:
            socket, _, controller = task["owner"].rpartition("#")
            if args.pane == controller:
                raise ValueError("fresh worker cannot use the controller pane")
            for path in root.glob("*/task.json"):
                other = json.loads(path.read_text(encoding="utf-8"))
                if other["owner"].rpartition("#")[0] == socket:
                    if any(a.get("pane") == args.pane for a in other["attempts"]):
                        raise ValueError("fresh worker cannot use a previously bound pane")
        if args.pane and attempt["pane"] is not None and attempt["pane"] != args.pane:
            raise ValueError("pane already bound; reconcile a move before changing identity")
        if args.pane:
            attempt["pane"] = args.pane
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
                                    args.launch_prompt)
        pair, refusal = single_pair(pairs)
        attempt["observed_source"] = str(args.transcript)
        attempt["observed_session"] = session
        if refusal:
            # A refused log clears earlier values so `accepted` cannot rest on them.
            attempt["observed_model"] = attempt["observed_effort"] = None
            event(task, "Observation refused: " + refusal, [str(args.transcript)])
            save_task(root, task)
            raise ValueError(refusal)
        model, effort = pair
        attempt["observed_model"] = model
        attempt["observed_effort"] = effort
        event(task, "Observed " + model + " / " + effort + " in the worker log",
              [str(args.transcript)])
        result["observed"] = {"model": model, "effort": effort}
    elif args.command == "receive":
        if task["state"] not in {"running", "reviewing"}:
            raise ValueError("receive requires a running or reviewing attempt")
        envelope = read_envelope(args.file, task, root)
        task["envelope"] = envelope
        task["state"] = "reviewing"
        event(task, "Received bounded envelope", [str(args.file)])
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
            "note": args.note,
        }
        attempt.setdefault("checks", []).append(record)
        event(task, "Recorded check " + record["id"] + " exit " + str(args.exit_status) +
              ": " + args.note, [path])
        result["check"] = record
    elif args.command == "update":
        if args.check and args.state != "accepted":
            raise ValueError("--check applies only to accepted")
        if args.state not in TRANSITIONS[task["state"]]:
            raise ValueError("invalid transition: " + task["state"] + " -> " + args.state)
        if args.state in {"starting", "running", "reviewing", "accepted", "retry"} and not args.evidence:
            raise ValueError("this transition requires observed evidence")
        if args.state == "starting" and not task["attempts"]:
            raise ValueError("reserve an attempt before resuming startup")
        if args.state in {"running", "reviewing", "accepted"}:
            if not task["attempts"] or not (task["attempts"][-1].get("pane") or task["attempts"][-1].get("session")):
                raise ValueError("bind the observed pane before recording execution")
        if strict and args.state == "accepted":
            envelope = task.get("envelope", {})
            if envelope.get("status") != "done" or not all(c["status"] == "pass" for c in envelope.get("criteria", [])):
                raise ValueError("acceptance requires a complete passing envelope and independent review")
            attempt = task["attempts"][-1]
            if (not model_matches(attempt.get("requested_model"), attempt.get("observed_model"))
                    or attempt.get("observed_effort") != attempt.get("effort")):
                raise ValueError("effective model/effort has not been observed to match the request")
            require_passing_check(attempt, args.check)
        task["state"] = args.state
        if args.state == "retry" and len(task["attempts"]) >= task["max_attempts"]:
            task["state"] = "needs-user"
        if task["state"] in TERMINAL or task["state"] == "needs-user":
            task["report_pending"] = True
        event(task, args.note, args.evidence)
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
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
