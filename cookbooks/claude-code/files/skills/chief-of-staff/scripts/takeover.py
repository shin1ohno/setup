#!/usr/bin/env python3
"""Move a controller's unfinished ledger tasks to another verified controller.

Used by the supervision handoff in references/supervision-handoff.md: when a
controller hands work to a stand-in, takes it back, or adopts it after the owner
answered through the question tool. Each task moves with `tasks.py handoff`, so
the ledger keeps both owners and the note in its history.

The caller must resolve (through the Herdr skill's caller-context helper) to the
--to owner; otherwise nothing moves. Terminal tasks stay with --from unless
--include-report-pending asks for accepted or cancelled results that were never
reported. A refusal, timeout or unreadable answer stops at that task; the run's
receipts file still records what moved, the failure and what did not move. Tasks
already moved are no longer listed under --from, so running the same command
again moves only the rest, and writes new files instead of replacing the old ones.
"""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys

TASKS = Path(__file__).with_name("tasks.py")
CALLER = Path(os.environ.get(
    "COS_CALLER_CONTEXT", "~/.agents/skills/herdr/caller-context.py")).expanduser()
TERMINAL = {"accepted", "cancelled"}


class Refused(Exception):
    """The takeover cannot start or cannot continue; the message says why."""


def state_root():
    return Path(os.environ.get(
        "COS_STATE_DIR", "~/.local/state/chief-of-staff")).expanduser().resolve()


def run_json(argv, timeout):
    """Run a helper and parse its JSON; every way it can fail becomes Refused."""
    name = f"{Path(argv[1]).name} {argv[2]}"
    try:
        result = subprocess.run(argv, capture_output=True, text=True,
                                stdin=subprocess.DEVNULL, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise Refused(f"{name} timed out after {timeout} s") from error
    except OSError as error:
        raise Refused(f"{name} could not start: {error}") from error
    if result.returncode:
        raise Refused(f"{name} failed: {(result.stderr or result.stdout).strip()[:400]}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise Refused(f"{name} printed no JSON: {result.stdout.strip()[:200]}") from error


def ledger(timeout, *args):
    return run_json([sys.executable, str(TASKS), *args], timeout)


def caller_owner(timeout):
    """Return the ledger owner key of the verified caller, or raise."""
    found = run_json([sys.executable, str(CALLER), "resolve"], timeout)
    if not found.get("verified"):
        raise Refused("caller context is not verified")
    if found.get("owner"):
        return found["owner"]
    if found.get("socket") and found.get("pane_id"):
        return f"{found['socket']}#{found['pane_id']}"
    raise Refused("caller context names no owner")


def selected(tasks, include_report_pending):
    for task in tasks:
        if task["state"] not in TERMINAL:
            yield task
        elif include_report_pending and task.get("report_pending"):
            yield task


def summary(root, task):
    attempts = task.get("attempts") or []
    last = attempts[-1] if attempts else {}
    number = last.get("number")
    return {"id": task["id"], "state": task["state"], "topic": task.get("topic", "")[:160],
            "attempt": number, "max_attempts": task.get("max_attempts"),
            "pane": last.get("pane"), "agent": last.get("agent"),
            "envelope": str(root / task["id"] / f"envelope-{number}.json") if number else None}


def parse(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--from", dest="source", required=True, help="Current ledger owner key")
    parser.add_argument("--to", dest="target", required=True,
                        help="New ledger owner key; must be the verified caller")
    parser.add_argument("--note", required=True,
                        help="Why the work moves; cite the owner's decision file")
    parser.add_argument("--out", help="Directory for this run's moved and receipts files")
    parser.add_argument("--dry-run", action="store_true", help="List what would move; change nothing")
    parser.add_argument("--include-report-pending", action="store_true",
                        help="Also move terminal tasks whose result was never reported")
    parser.add_argument("--timeout", type=float, default=60.0,
                        help="Seconds allowed for each helper call (default 60)")
    args = parser.parse_args(argv)
    if not args.note.strip():
        parser.error("--note must not be blank")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    return args


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


def takeover(args):
    caller = caller_owner(args.timeout)
    if caller != args.target:
        raise Refused(f"caller {caller} is not --to {args.target}")
    if args.source == args.target and not args.dry_run:
        raise Refused("--from and --to are the same owner")
    root = state_root()
    listed = ledger(args.timeout, "list", "--owner", args.source)["tasks"]
    moving = [summary(root, task) for task in selected(listed, args.include_report_pending)]
    # Each run writes its own files, so a rerun after a failure keeps the earlier record.
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    out = Path(args.out).expanduser() if args.out else root / f"takeover-{stamp}"
    out.mkdir(mode=0o700, parents=True, exist_ok=True)
    kind = "dry-run" if args.dry_run else "run"
    moved_file = out / f"moved-{kind}-{stamp}.json"
    receipts_file = None if args.dry_run else out / f"receipts-{stamp}.json"
    write_json(moved_file, moving)
    receipts, failure = [], None
    if not args.dry_run:
        try:
            for item in moving:
                try:
                    result = ledger(args.timeout, "handoff", item["id"], "--owner", args.source,
                                    "--to", args.target, "--note", args.note)
                    receipts.append({"id": item["id"], "owner": result["task"]["owner"],
                                     "at": result["task"]["history"][-1]["at"]})
                except (Refused, KeyError, TypeError, IndexError) as error:
                    # A timed-out handoff may still have landed; the ledger history is the truth.
                    failure = {"id": item["id"], "error": str(error),
                               "check": f"tasks.py show {item['id']} decides whether it moved"}
                    break
        finally:
            done = {item["id"] for item in receipts}
            write_json(receipts_file, {
                "from": args.source, "to": args.target, "note": args.note, "moved": receipts,
                "failure": failure,
                "not_moved": [item["id"] for item in moving if item["id"] not in done]})
    states = {}
    for item in moving:
        states[item["state"]] = states.get(item["state"], 0) + 1
    report = {"dry_run": args.dry_run, "from": args.source, "to": args.target,
              "selected": len(moving), "moved": len(receipts), "states": states,
              "failure": failure, "moved_file": str(moved_file),
              "receipts_file": str(receipts_file) if receipts_file else None}
    if failure:
        raise Refused(json.dumps(report, ensure_ascii=False))
    return report


def main(argv=None):
    args = parse(sys.argv[1:] if argv is None else argv)
    try:
        print(json.dumps(takeover(args), ensure_ascii=False))
    except Refused as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
