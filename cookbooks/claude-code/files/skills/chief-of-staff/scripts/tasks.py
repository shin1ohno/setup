#!/usr/bin/env python3
"""Private, atomic task ledger shared by Claude Code and Codex controllers."""

import argparse
import contextlib
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import re
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
    for name in ("show", "attempt", "bind", "update", "reported", "extend", "receive"):
        cmd = sub.add_parser(name)
        cmd.add_argument("task_id")
        cmd.add_argument("--owner", type=nonempty)
        if name == "attempt":
            cmd.add_argument("--kind", choices=("claude", "codex"), required=True)
            cmd.add_argument("--model", required=True, type=nonempty)
            cmd.add_argument("--reason", required=True, type=nonempty)
            cmd.add_argument("--effort", choices=("low", "medium", "high", "xhigh", "max", "ultra"))
            cmd.add_argument("--route", choices=("herdr", "agent"), default="herdr")
            cmd.add_argument("--profile", choices=("common", "dev", "cos", "writing"), default="dev")
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
        elif name == "update":
            cmd.add_argument("--state", choices=TRANSITIONS, required=True)
            cmd.add_argument("--note", required=True, type=nonempty)
            cmd.add_argument("--evidence", action="append", type=nonempty, default=[])
        elif name in {"reported", "extend"}:
            cmd.add_argument("--note", required=True, type=nonempty)
            if name == "extend":
                cmd.add_argument("--max-attempts", required=True, type=positive)
    return cli


def read_envelope(path, task, root):
    """Validate structure and evidence locations; never claim artifact quality."""
    roots = [Path(task["cwd"]).resolve(), task_path(root, task["id"]).parent.resolve()]
    if not path.is_absolute() or not any(path.resolve().is_relative_to(r) for r in roots):
        raise ValueError("envelope must be inside the task or checkout")
    with path.open("rb") as stream:
        data = stream.read(16385)
    if len(data) > 16384:
        raise ValueError("envelope exceeds 16 KiB")
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
            raise ValueError("reuse requires the previous worker's same kind and model")
        attempt = {
            "number": len(task["attempts"]) + 1,
            "agent": "cos-" + task["id"] + "-" + str(len(task["attempts"]) + 1),
            "kind": args.kind, "model": args.model, "reason": args.reason,
            "requested_model": args.model, "effort": args.effort,
            "observed_model": None, "observed_effort": None,
            "route": args.route, "profile": args.profile, "session": None,
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
        if (attempt.get("route", "herdr") == "herdr") != bool(args.pane):
            raise ValueError("bind the identity returned by the selected route")
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
    elif args.command == "receive":
        if task["state"] not in {"running", "reviewing"}:
            raise ValueError("receive requires a running or reviewing attempt")
        envelope = read_envelope(args.file, task, root)
        task["envelope"] = envelope
        task["state"] = "reviewing"
        event(task, "Received bounded envelope", [str(args.file)])
        result["envelope"] = envelope
    elif args.command == "update":
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
            if (attempt.get("observed_model") != attempt.get("requested_model")
                    or attempt.get("observed_effort") != attempt.get("effort")):
                raise ValueError("effective model/effort has not been observed to match the request")
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
