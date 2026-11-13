#!/usr/bin/env python3
"""Move a controller's unfinished ledger tasks to another verified controller.

Used by the supervision handoff in references/supervision-handoff.md: when a
controller hands work to a stand-in, takes it back, or adopts it after the owner
answered through the question tool. Each task moves with `tasks.py handoff`, so
the ledger keeps both owners and the note in its history.

The caller must resolve (through the Herdr skill's caller-context helper) to the
--to owner; otherwise nothing moves. Terminal tasks stay with --from unless
--include-report-pending asks for accepted or cancelled results that were never
reported. A failure stops at that task; tasks already moved are no longer listed
under --from, so running the same command again moves only the rest.
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


def run_json(argv):
    result = subprocess.run(argv, capture_output=True, text=True,
                            stdin=subprocess.DEVNULL, timeout=60)
    if result.returncode:
        raise Refused(f"{Path(argv[1]).name} {argv[2]} failed: "
                      f"{(result.stderr or result.stdout).strip()[:400]}")
    return json.loads(result.stdout)


def ledger(*args):
    return run_json([sys.executable, str(TASKS), *args])


def caller_owner():
    """Return the ledger owner key of the verified caller, or raise."""
    found = run_json([sys.executable, str(CALLER), "resolve"])
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
    parser.add_argument("--out", help="Directory for moved.json and receipts.json")
    parser.add_argument("--dry-run", action="store_true", help="List what would move; change nothing")
    parser.add_argument("--include-report-pending", action="store_true",
                        help="Also move terminal tasks whose result was never reported")
    args = parser.parse_args(argv)
    if not args.note.strip():
        parser.error("--note must not be blank")
    return args


def takeover(args):
    caller = caller_owner()
    if caller != args.target:
        raise Refused(f"caller {caller} is not --to {args.target}")
    if args.source == args.target and not args.dry_run:
        raise Refused("--from and --to are the same owner")
    root = state_root()
    listed = ledger("list", "--owner", args.source)["tasks"]
    moving = [summary(root, task) for task in selected(listed, args.include_report_pending)]
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = Path(args.out).expanduser() if args.out else root / f"takeover-{stamp}"
    out.mkdir(mode=0o700, parents=True, exist_ok=True)
    (out / ("moved-dry-run.json" if args.dry_run else "moved.json")).write_text(
        json.dumps(moving, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    receipts, failure = [], None
    if not args.dry_run:
        for item in moving:
            try:
                result = ledger("handoff", item["id"], "--owner", args.source,
                                "--to", args.target, "--note", args.note)
            except Refused as error:
                failure = {"id": item["id"], "error": str(error)}
                break
            receipts.append({"id": item["id"], "owner": result["task"]["owner"],
                             "at": result["task"]["history"][-1]["at"]})
        (out / "receipts.json").write_text(
            json.dumps({"from": args.source, "to": args.target, "note": args.note,
                        "moved": receipts, "failure": failure}, ensure_ascii=False, indent=1) + "\n",
            encoding="utf-8")
    states = {}
    for item in moving:
        states[item["state"]] = states.get(item["state"], 0) + 1
    report = {"dry_run": args.dry_run, "from": args.source, "to": args.target,
              "selected": len(moving), "moved": len(receipts), "states": states,
              "failure": failure, "out": str(out)}
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
