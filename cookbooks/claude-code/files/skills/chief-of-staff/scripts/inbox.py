#!/usr/bin/env python3
"""Post one structured report from a Chief of Staff worker to its task inbox.

A worker (Claude Code or Codex) runs `inbox.py post` with the task directory,
task ID, attempt and attempt nonce from its brief. The message lands as one
JSON file in <task-dir>/inbox/; the controller reads it with `tasks.py inbox`,
which validates every field again. This helper never reads or writes task.json.

`inbox.py tasks` records the worker's task checklist (up to two levels of
items, each todo, doing, done or failed) in <task-dir>/checklist-<attempt>.json,
replaced atomically, with a capped log of item state changes. The Agent Board
(board.rb) shows it and checks the task ID, attempt and nonce against the
ledger again.

The inbox gives cooperating workers a structured, attributable channel. It is
not an authentication boundary: a worker runs as the same OS user as the
controller and can write any file in the state directory.
"""

import argparse
import contextlib
from datetime import datetime, timezone
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import stat
import sys
import time
import unicodedata


KINDS = ("done", "failed", "blocked", "question", "wait", "step", "note")
KEYS = frozenset({"task_id", "attempt", "nonce", "kind", "text", "on", "step", "at"})
TEXT_LIMIT = 1200
ON_LIMIT = 80
AT_LIMIT = 40
FILE_LIMIT = 8192
CHECKLIST_STATES = ("todo", "doing", "done", "failed")
CHECKLIST_KEYS = frozenset({"task_id", "attempt", "nonce", "at", "started_at", "items", "changes"})
CHECKLIST_INPUT_LIMIT = 32 * 1024
CHECKLIST_FILE_LIMIT = 64 * 1024
CHECKLIST_TEXT_LIMIT = 200
CHECKLIST_ITEMS = 30
CHECKLIST_CHILDREN = 15
CHECKLIST_LEAVES = 80
CHECKLIST_CHANGES = 200
NONCE = re.compile(r"[0-9a-f]{16}")
STEP = re.compile(r"[0-9]{1,3}/[0-9]{1,3}")
# <attempt>-<time_ns>-<random hex>.json; the reader accepts nothing else.
NAME = re.compile(r"[1-9][0-9]{0,2}-[0-9]+-[0-9a-f]{8,}\.json")

# CSI / OSC / two-byte escape sequences, removed before the lone controls.
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b[@-_]")
# C0 (newline and tab are folded to a space first), DEL and C1 controls.
CONTROLS = re.compile(r"[\x00-\x1f\x7f-\x9f]")
# Bidi embeddings, overrides and isolates, marks, and zero-width characters.
INVISIBLE = re.compile("[­؜᠎​-‏‪-‮⁠-⁩﻿]")


def clean(value, limit=None):
    """Fold a worker string into one safe display line.

    Removes ANSI escapes, C0/C1 controls (newlines become spaces), bidi
    controls and zero-width characters, replaces backticks so the text cannot
    close a Markdown code fence, normalizes to NFC, and cuts at `limit` UTF-8
    bytes on a character boundary.
    """
    value = ANSI.sub("", value)
    value = re.sub(r"[\r\n\t\v\f  \x85]", " ", value)
    value = CONTROLS.sub("", value)
    value = INVISIBLE.sub("", value)
    value = value.replace("`", "'")
    value = unicodedata.normalize("NFC", value).strip()
    if limit is not None:
        value = value.encode("utf-8")[:limit].decode("utf-8", "ignore")
    return value


def task_id_pattern():
    """The ledger's own task ID pattern, loaded from tasks.py beside this file."""
    path = Path(__file__).resolve().with_name("tasks.py")
    spec = importlib.util.spec_from_file_location("cos_tasks_for_inbox", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.TASK_ID


class Refused(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Refused(message)


def parser():
    cli = Parser(description=__doc__.splitlines()[0])
    sub = cli.add_subparsers(dest="command", required=True, parser_class=Parser)
    post = sub.add_parser("post", help="Write one message into <task-dir>/inbox/")
    post.add_argument("--task-dir", required=True, help="Absolute task directory from the brief")
    post.add_argument("--task-id", required=True)
    post.add_argument("--attempt", required=True)
    post.add_argument("--nonce", required=True, help="Attempt nonce from the brief")
    post.add_argument("--kind", required=True, choices=KINDS)
    post.add_argument("--text", required=True)
    post.add_argument("--on", help="Who or what a `wait` is waiting on")
    post.add_argument("--step", help="Progress as i/n for a `step`")
    tasks = sub.add_parser("tasks", help="Replace <task-dir>/checklist-<attempt>.json with the "
                                         "worker's task checklist")
    tasks.add_argument("--task-dir", required=True, help="Absolute task directory from the brief")
    tasks.add_argument("--task-id", required=True)
    tasks.add_argument("--attempt", required=True)
    tasks.add_argument("--nonce", required=True, help="Attempt nonce from the brief")
    tasks.add_argument("--items", required=True,
                       help='JSON list of {"text", "state", "children"?}, or - to read it from '
                            "stdin; children are one level of {\"text\", \"state\"}")
    return cli


def identity(args):
    """The task ID, attempt and nonce checks shared by `post` and `tasks`."""
    if not task_id_pattern().fullmatch(args.task_id):
        raise Refused("invalid task ID")
    if not re.fullmatch(r"[1-9][0-9]{0,2}", args.attempt):
        raise Refused("attempt must be an integer from 1 to 999")
    if not NONCE.fullmatch(args.nonce):
        raise Refused("nonce must be the 16 hex characters from the brief")


def message(args):
    identity(args)
    text = clean(args.text)
    if not text:
        raise Refused("text is empty after cleaning")
    if len(text.encode("utf-8")) > TEXT_LIMIT:
        raise Refused(f"text exceeds {TEXT_LIMIT} UTF-8 bytes after cleaning; shorten it "
                      "and put the detail in a report file")
    on = None
    if args.on is not None:
        on = clean(args.on)
        if not on or len(on.encode("utf-8")) > ON_LIMIT:
            raise Refused(f"--on must be 1 to {ON_LIMIT} UTF-8 bytes after cleaning")
    if args.kind == "wait" and on is None:
        raise Refused("a wait message needs --on WHO")
    if args.step is not None and not STEP.fullmatch(args.step):
        raise Refused("--step must look like i/n (up to three digits each)")
    if args.kind == "step" and args.step is None:
        raise Refused("a step message needs --step i/n")
    return {
        "task_id": args.task_id, "attempt": int(args.attempt), "nonce": args.nonce,
        "kind": args.kind, "text": text, "on": on, "step": args.step,
        "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }


def open_task_dir(task_dir, task_id):
    """Open the task directory without following a final symlink."""
    path = Path(task_dir)
    if not path.is_absolute():
        raise Refused("--task-dir must be an absolute path")
    if path.name != task_id:
        raise Refused("--task-dir does not belong to --task-id")
    try:
        directory = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as error:
        raise Refused(f"--task-dir is not a directory: {error.strerror}") from None
    try:
        # The ledger record must exist; it is only checked, never opened.
        info = os.stat("task.json", dir_fd=directory, follow_symlinks=False)
        if not stat.S_ISREG(info.st_mode):
            raise Refused("--task-dir has no ledger task.json")
    except FileNotFoundError:
        os.close(directory)
        raise Refused("--task-dir has no ledger task.json") from None
    except BaseException:
        os.close(directory)
        raise
    return directory


def post(args):
    body = message(args)
    data = (json.dumps(body, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")
    if len(data) > FILE_LIMIT:
        raise Refused(f"message exceeds {FILE_LIMIT} bytes")
    directory = open_task_dir(args.task_dir, args.task_id)
    try:
        try:
            os.mkdir("inbox", mode=0o700, dir_fd=directory)
        except FileExistsError:
            pass
        try:
            inbox = os.open("inbox", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                            dir_fd=directory)
        except OSError as error:
            raise Refused(f"inbox is not a directory: {error.strerror}") from None
    finally:
        os.close(directory)
    try:
        temporary = ".post-" + secrets.token_hex(8) + ".tmp"
        handle = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW |
                         os.O_CLOEXEC, 0o600, dir_fd=inbox)
        try:
            os.write(handle, data)
            os.fsync(handle)
        finally:
            os.close(handle)
        try:
            for _ in range(16):
                name = f"{body['attempt']}-{time.time_ns()}-{secrets.token_hex(8)}.json"
                try:
                    # link() refuses an existing name, so no message is overwritten.
                    os.link(temporary, name, src_dir_fd=inbox, dst_dir_fd=inbox)
                    break
                except FileExistsError:
                    continue
            else:
                raise Refused("could not choose a unique message name")
        finally:
            os.unlink(temporary, dir_fd=inbox)
    finally:
        os.close(inbox)
    return {"posted": name, "inbox": str(Path(args.task_dir) / "inbox")}


def checklist_items(raw):
    """Validate and clean the worker's checklist; return the items as stored."""
    if len(raw.encode("utf-8")) > CHECKLIST_INPUT_LIMIT:
        raise Refused(f"--items exceeds {CHECKLIST_INPUT_LIMIT} bytes")
    try:
        items = json.loads(raw)
    except ValueError:
        raise Refused("--items is not valid JSON") from None
    if not isinstance(items, list) or not items:
        raise Refused("--items must be a non-empty JSON list")
    if len(items) > CHECKLIST_ITEMS:
        raise Refused(f"--items holds more than {CHECKLIST_ITEMS} top-level items")

    def item(value, where, nested):
        if not isinstance(value, dict):
            raise Refused(f"item {where} must be an object")
        if nested and "children" in value:
            raise Refused(f"item {where} cannot have children: the checklist has two levels")
        if not {"text", "state"} <= set(value) <= {"text", "state", "children"}:
            raise Refused(f"item {where} needs text and state, and optional children only")
        if not isinstance(value["text"], str):
            raise Refused(f"item {where} text must be a string")
        text = clean(value["text"])
        if not text:
            raise Refused(f"item {where} text is empty after cleaning")
        if len(text.encode("utf-8")) > CHECKLIST_TEXT_LIMIT:
            raise Refused(f"item {where} text exceeds {CHECKLIST_TEXT_LIMIT} UTF-8 bytes after "
                          "cleaning")
        if value["state"] not in CHECKLIST_STATES:
            raise Refused(f"item {where} state must be one of {', '.join(CHECKLIST_STATES)}")
        stored = {"text": text, "state": value["state"]}
        if not nested and "children" in value:
            children = value["children"]
            if not isinstance(children, list):
                raise Refused(f"item {where} children must be a list")
            if len(children) > CHECKLIST_CHILDREN:
                raise Refused(f"item {where} has more than {CHECKLIST_CHILDREN} children")
            if children:
                stored["children"] = [item(child, f"{where}.{index}", True)
                                      for index, child in enumerate(children, 1)]
        return stored

    stored = [item(value, str(index), False) for index, value in enumerate(items, 1)]
    if checklist_leaves(stored) > CHECKLIST_LEAVES:
        raise Refused(f"--items holds more than {CHECKLIST_LEAVES} leaf items")
    return stored


def checklist_leaf_items(items):
    """Items without children, plus every child: what the progress bar counts."""
    return [leaf for entry in items for leaf in (entry.get("children") or [entry])]


def checklist_leaves(items):
    return len(checklist_leaf_items(items))


def checklist_states(items):
    """(parent text or None, text) -> state, first occurrence wins."""
    states = {}
    for entry in items:
        states.setdefault((None, entry["text"]), entry["state"])
        for child in entry.get("children", ()):
            states.setdefault((entry["text"], child["text"]), child["state"])
    return states


def existing_checklist(directory, name):
    """The parsed checklist file now at `name`, or None when absent or unreadable."""
    try:
        handle = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                         dir_fd=directory)
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(handle).st_mode):
            return None
        data = os.read(handle, CHECKLIST_FILE_LIMIT + 1)
    finally:
        os.close(handle)
    try:
        body = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return None
    return body if isinstance(body, dict) else None


def previous_checklist(body, args):
    """The earlier checklist of this attempt, or None when absent or not ours."""
    if (body is None or set(body) != CHECKLIST_KEYS or
            body["task_id"] != args.task_id or body["attempt"] != int(args.attempt) or
            body["nonce"] != args.nonce or not isinstance(body["items"], list) or
            not isinstance(body["changes"], list)):
        return None
    try:
        checklist_states(body["items"])
    except (AttributeError, KeyError, TypeError):
        return None
    return body


def record_checklist(args):
    identity(args)
    raw = sys.stdin.read(CHECKLIST_INPUT_LIMIT + 1) if args.items == "-" else args.items
    items = checklist_items(raw)
    at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    name = f"checklist-{int(args.attempt)}.json"
    directory = open_task_dir(args.task_dir, args.task_id)
    try:
        # One writer at a time per task directory, so no state change is lost.
        fcntl.flock(directory, fcntl.LOCK_EX)
        existing = existing_checklist(directory, name)
        # Another nonce for the same attempt is not this worker's brief: keep
        # the recorded checklist instead of replacing it.
        if (existing is not None and existing.get("attempt") == int(args.attempt) and
                isinstance(existing.get("nonce"), str) and existing["nonce"] != args.nonce):
            raise Refused(f"{name} was recorded with a different nonce for attempt "
                          f"{int(args.attempt)}; refusing to replace it")
        previous = previous_checklist(existing, args)
        changes = [entry for entry in previous["changes"] if isinstance(entry, dict)] \
            if previous else []
        before = checklist_states(previous["items"]) if previous else {}
        after = checklist_states(items)
        if not previous or checklist_leaves(previous["items"]) != checklist_leaves(items):
            changes.append({"at": at, "plan": checklist_leaves(items)})
        if previous:
            for (parent, text), state in after.items():
                if before.get((parent, text)) != state and not (
                        (parent, text) not in before and state == "todo"):
                    changes.append({"at": at, "parent": parent, "text": text,
                                    "from": before.get((parent, text)), "to": state})
        body = {"task_id": args.task_id, "attempt": int(args.attempt), "nonce": args.nonce,
                "at": at, "started_at": previous["started_at"] if previous and
                isinstance(previous["started_at"], str) else at,
                "items": items, "changes": changes[-CHECKLIST_CHANGES:]}
        while True:
            data = (json.dumps(body, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")
            if len(data) <= CHECKLIST_FILE_LIMIT:
                break
            if not body["changes"]:
                raise Refused(f"checklist exceeds {CHECKLIST_FILE_LIMIT} bytes")
            body["changes"] = body["changes"][1:]
        temporary = ".checklist-" + secrets.token_hex(8) + ".tmp"
        handle = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW |
                         os.O_CLOEXEC, 0o600, dir_fd=directory)
        try:
            try:
                os.write(handle, data)
                os.fsync(handle)
            finally:
                os.close(handle)
            # rename() replaces the name itself, never a file a symlink points to.
            os.replace(temporary, name, src_dir_fd=directory, dst_dir_fd=directory)
        except BaseException:
            with contextlib.suppress(OSError):
                os.unlink(temporary, dir_fd=directory)
            raise
    finally:
        os.close(directory)
    return {"recorded": name, "leaves": checklist_leaves(items),
            "done": sum(1 for leaf in checklist_leaf_items(items) if leaf["state"] == "done"),
            "changes": len(body["changes"])}


def main(argv=None):
    try:
        args = parser().parse_args(argv)
        result = record_checklist(args) if args.command == "tasks" else post(args)
    except Refused as error:
        print("inbox.py: refused: " + " ".join(str(error).split()), file=sys.stderr)
        return 1
    except OSError as error:
        print("inbox.py: refused: " + " ".join(str(error).split()), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
