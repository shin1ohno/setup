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
    "needs-user": {"reviewing", "retry", "cancelled"},
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
    new.add_argument("--max-attempts", type=positive, default=3)
    ls = sub.add_parser("list", help="List only this controller's tasks")
    ls.add_argument("--owner", required=True, type=nonempty)
    ls.add_argument("--all", action="store_true", help="Include terminal tasks")
    for name in ("show", "attempt", "bind", "update", "reported", "extend"):
        cmd = sub.add_parser(name)
        cmd.add_argument("task_id")
        if name == "attempt":
            cmd.add_argument("--kind", choices=("claude", "codex"), required=True)
            cmd.add_argument("--model", required=True, type=nonempty)
            cmd.add_argument("--reason", required=True, type=nonempty)
        elif name == "bind":
            cmd.add_argument("--pane", required=True, type=nonempty)
            cmd.add_argument("--model", type=nonempty)
        elif name == "update":
            cmd.add_argument("--state", choices=TRANSITIONS, required=True)
            cmd.add_argument("--note", required=True, type=nonempty)
            cmd.add_argument("--evidence", action="append", type=nonempty, default=[])
        elif name in {"reported", "extend"}:
            cmd.add_argument("--note", required=True, type=nonempty)
            if name == "extend":
                cmd.add_argument("--max-attempts", required=True, type=positive)
    return cli


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
            "created_at": now(), "last_report": None,
        }
        event(task, "Task created")
        save_task(root, task)
        return {"task": task, "directory": str(task_path(root, task_id).parent)}
    if args.command == "list":
        tasks = [json.loads(path.read_text(encoding="utf-8"))
                 for path in sorted(root.glob("*/task.json"))]
        return {"tasks": [task for task in tasks if task["owner"] == args.owner
                          and (args.all or task["state"] not in TERMINAL)]}

    task = read_task(root, args.task_id)
    result = {}
    if args.command == "show":
        return {"task": task}
    if args.command == "attempt":
        if task["state"] not in {"queued", "retry", "needs-user"}:
            raise ValueError("reconcile the existing attempt before reserving another")
        if len(task["attempts"]) >= task["max_attempts"]:
            raise ValueError("attempt budget exhausted; explicit user extension required")
        attempt = {
            "number": len(task["attempts"]) + 1,
            "agent": "cos-" + task["id"] + "-" + str(len(task["attempts"]) + 1),
            "kind": args.kind, "model": args.model, "reason": args.reason,
            "pane": None, "created_at": now(),
        }
        task["attempts"].append(attempt)
        task["state"] = "starting"
        event(task, args.reason)
        result["attempt"] = attempt
    elif args.command == "bind":
        if task["state"] not in {"starting", "running", "reviewing"}:
            raise ValueError("bind requires a live attempt")
        attempt = task["attempts"][-1]
        if attempt["pane"] is not None and attempt["pane"] != args.pane:
            raise ValueError("pane already bound; reconcile a move before changing identity")
        attempt["pane"] = args.pane
        if args.model:
            attempt["model"] = args.model
        event(task, "Bound pane " + args.pane)
    elif args.command == "update":
        if args.state not in TRANSITIONS[task["state"]]:
            raise ValueError("invalid transition: " + task["state"] + " -> " + args.state)
        if args.state in {"running", "reviewing", "accepted", "retry"} and not args.evidence:
            raise ValueError("this transition requires observed evidence")
        if args.state in {"running", "reviewing", "accepted"}:
            if not task["attempts"] or task["attempts"][-1]["pane"] is None:
                raise ValueError("bind the observed pane before recording execution")
        task["state"] = args.state
        if args.state == "retry" and len(task["attempts"]) >= task["max_attempts"]:
            task["state"] = "needs-user"
        event(task, args.note, args.evidence)
    elif args.command == "reported":
        task["last_report"] = {"at": now(), "note": args.note}
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
    except (ValueError, OSError, KeyError) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
