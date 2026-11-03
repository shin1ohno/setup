#!/usr/bin/env python3
"""Resolve a local caller without consulting Herdr's focused pane.

Shared app-server tools have no terminal ancestry. In that case, use a short
two-call visual challenge, bound to CODEX_SESSION_ID. No terminal input is sent.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time
import uuid

TTL = 120


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE, timeout=15)


def api(session, *args):
    return json.loads(run("herdr", "--session", session, *args))["result"]


def inventory():
    # Listing is read-only. Never use an unknown --session: it can create one.
    sessions = json.loads(run("herdr", "session", "list", "--json"))["sessions"]
    found = []
    for session in sessions:
        if not session["running"]:
            continue
        name = session["name"]
        for pane in api(name, "api", "snapshot")["snapshot"]["panes"]:
            found.append(dict(pane, session=name, socket=session["socket_path"]))
    return found


def process(pane):
    return api(pane["session"], "pane", "process-info", "--pane", pane["pane_id"])["process_info"]


def ancestors():
    result = set()
    pid = os.getpid()
    while pid > 1 and pid not in result:
        result.add(pid)
        pid = int(run("ps", "-o", "ppid=", "-p", str(pid)).strip())
    return result


def identity(pane):
    return (pane["socket"], pane["pane_id"], pane["workspace_id"], pane["tab_id"])


def inherited(panes, env, parent_pids, get_process=process):
    if env.get("HERDR_ENV") != "1" or not env.get("HERDR_PANE_ID"):
        return None
    candidates = []
    for pane in panes:
        if pane["pane_id"] != env["HERDR_PANE_ID"]:
            continue
        if pane["workspace_id"] != env.get("HERDR_WORKSPACE_ID"):
            continue
        if env.get("HERDR_TAB_ID") and pane["tab_id"] != env["HERDR_TAB_ID"]:
            continue
        info = get_process(pane)
        # Env alone is insufficient: reject stale/fabricated IDs and daemon
        # ancestry. An actual pane foreground process must be an ancestor.
        if any(p["pid"] in parent_pids for p in info["foreground_processes"]):
            candidates.append(pane)
    if len(candidates) > 1:
        raise ValueError("ambiguous inherited caller")
    return candidates[0] if candidates else None


def challenge_match(panes, state, session_id, now, read, get_process=process):
    if state["session_id"] != session_id or not 0 <= now - state["created"] <= TTL:
        raise ValueError("expired or unrelated session challenge; prepare again")
    matches = []
    for pane in panes:
        if state["marker"] not in read(pane):
            continue
        info = get_process(pane)
        foreground = info["foreground_processes"]
        if pane.get("agent") != "codex" or not foreground:
            raise ValueError("challenge found outside a live Codex pane")
        if not all(Path(p["argv"][0]).name == "codex" for p in foreground):
            raise ValueError("challenge foreground process changed")
        if state["processes"].get(pane["socket"] + "#" + pane["pane_id"]) != [p["pid"] for p in foreground]:
            raise ValueError("challenge pane occupant replaced since prepare")
        matches.append((pane, tuple(p["pid"] for p in foreground)))
    if len(matches) != 1:
        raise ValueError("challenge absent or ambiguous; no caller selected")
    return matches[0]


def state_path(session_id):
    if str(uuid.UUID(session_id)) != session_id:
        raise ValueError("invalid CODEX_SESSION_ID")
    root = Path.home() / ".local/state/herdr-caller"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    return root / (session_id + ".json")


def emit(pane, method):
    print(json.dumps({"verified": True, "method": method,
                      **{k: pane[k] for k in ("session", "socket", "pane_id", "workspace_id", "tab_id")}}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["resolve", "prepare", "verify"])
    args = parser.parse_args()
    if args.action == "resolve":
        pane = inherited(inventory(), os.environ, ancestors())
        if pane is None:
            raise ValueError("no verified inherited caller; use prepare then verify in separate tool calls")
        emit(pane, "foreground-ancestry")
        return
    session_id = os.environ.get("CODEX_SESSION_ID", "")
    path = state_path(session_id)
    if args.action == "prepare":
        processes = {}
        for pane in inventory():
            if pane.get("agent") == "codex":
                processes[pane["socket"] + "#" + pane["pane_id"]] = [
                    p["pid"] for p in process(pane)["foreground_processes"]]
        state = {"session_id": session_id, "created": time.time(),
                 "marker": "HERDR-CALLER-PROOF-" + secrets.token_hex(24), "processes": processes}
        # Private, atomic state, with no environment values or transcript.
        tmp = path.with_suffix("." + secrets.token_hex(8))
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(state, stream)
        os.replace(tmp, path)
        print(state["marker"], flush=True)
        print("Run verify in the next separate tool call, within 120 seconds. Do not copy this proof into another pane.")
        return
    state = json.loads(path.read_text())
    def read(pane):
        return run("herdr", "--session", pane["session"], "pane", "read", pane["pane_id"],
                   "--source", "recent-unwrapped", "--lines", "1000")
    pane, pids = challenge_match(inventory(), state, session_id, time.time(), read)
    # Recheck live topology/processes after collecting the snapshots.
    live = [p for p in inventory() if identity(p) == identity(pane)]
    if len(live) != 1 or tuple(p["pid"] for p in process(live[0])["foreground_processes"]) != pids:
        raise ValueError("caller changed during verification")
    if time.time() - state["created"] > TTL:
        raise ValueError("challenge expired during verification")
    path.unlink()  # one use; future operations must revalidate
    emit(pane, "session-visual-challenge")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        # Never echo subprocess stdout/stderr (it may contain pane transcripts).
        print(json.dumps({"verified": False, "error": str(error) if isinstance(error, ValueError)
                          else type(error).__name__}), file=sys.stderr)
        sys.exit(1)
