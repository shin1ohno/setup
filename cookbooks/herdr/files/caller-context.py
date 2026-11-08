#!/usr/bin/env python3
"""Resolve a local caller without consulting Herdr's focused pane.

Shared app-server tools have no terminal ancestry. In that case, use a short
two-call visual challenge, bound to CODEX_SESSION_ID. The assistant must display
the challenge in commentary; tool output may be hidden by the TUI.
No terminal input is sent.
"""
import argparse
import json
import os
from pathlib import Path
import re
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


def codex_foreground(pane, info):
    foreground = info["foreground_processes"]
    return (pane.get("agent") == "codex" and bool(foreground)
            and all(p.get("argv") and Path(p["argv"][0]).name == "codex"
                    for p in foreground))


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
        # The TUI itself can insert hard line breaks when laying out assistant
        # text. recent-unwrapped only removes terminal soft wraps, not these.
        if state["marker"] not in "".join(read(pane).split()):
            continue
        info = get_process(pane)
        foreground = info["foreground_processes"]
        if not codex_foreground(pane, info):
            raise ValueError("challenge found outside a live Codex pane")
        if state["processes"].get(pane["socket"] + "#" + pane["pane_id"]) != [p["pid"] for p in foreground]:
            raise ValueError("challenge pane occupant replaced since prepare")
        matches.append((pane, tuple(p["pid"] for p in foreground)))
    if len(matches) != 1:
        raise ValueError("challenge absent or ambiguous; no caller selected")
    return matches[0]


def state_path(session_id):
    try:
        valid = str(uuid.UUID(session_id)) == session_id
    except (ValueError, AttributeError, TypeError):
        valid = False
    if not valid:
        raise ValueError("prepare/verify require a canonical UUID CODEX_SESSION_ID for "
                         "Herdr 1 Codex visual proof; hc controllers must use resolve")
    root = Path.home() / ".local/state/herdr-caller"
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    return root / (session_id + ".json")


def resumed_session(panes, session_id, get_process=process):
    """Bind a daemon request to a unique live `codex resume <UUID>` client.

    Session identity comes from the harness, not pane focus or transcript text.
    Do not match UUID substrings, --last, or an option's value as a resume ID.
    """
    try:
        if str(uuid.UUID(session_id)) != session_id:
            return None
    except (ValueError, AttributeError):
        return None
    matches = []
    for pane in panes:
        info = get_process(pane)
        if not codex_foreground(pane, info):
            continue
        foreground = info["foreground_processes"]
        if all(p["argv"][1:3] == ["resume", session_id] for p in foreground):
            matches.append((pane, tuple(p["pid"] for p in foreground)))
    if len(matches) > 1:
        raise ValueError("ambiguous live Codex resume session")
    return matches[0] if matches else None


def recheck(pane, pids):
    live = [p for p in inventory() if identity(p) == identity(pane)]
    if len(live) != 1:
        raise ValueError("caller changed during verification")
    info = process(live[0])
    if (not codex_foreground(live[0], info)
            or tuple(p["pid"] for p in info["foreground_processes"]) != pids):
        raise ValueError("caller changed during verification")
    return live[0], info


def emit(pane, method):
    print(json.dumps({"verified": True, "method": method,
                      **{k: pane[k] for k in ("session", "socket", "pane_id", "workspace_id", "tab_id")}}))


def hc_identity(env, parent_pids):
    """Use hc's live local process observations, never the inherited ID alone."""
    terminal = env["HC_TERMINAL_ID"]
    server = env.get("HC_SESSION", "").strip() or "default"
    if not re.fullmatch(r"t[0-9a-z]+", terminal) or "#" in server:
        raise ValueError("hc caller unverified: invalid local terminal or server identifier")

    def observe():
        try:
            info = json.loads(run("hc", "get", "--json", terminal))
        except subprocess.CalledProcessError as error:
            reason = "terminal not found" if error.returncode == 3 else "exit " + str(error.returncode)
            raise ValueError("hc caller unverified: hc get failed (" + reason + ")") from None
        except subprocess.TimeoutExpired:
            raise ValueError("hc caller unverified: hc get failed (timed out)") from None
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            raise ValueError("hc caller unverified: hc get failed (" +
                             type(error).__name__ + ")") from None
        if not isinstance(info, dict) or info.get("address") != terminal:
            raise ValueError("hc caller unverified: hc returned a different terminal")
        if info.get("state") != "live":
            raise ValueError("hc caller unverified: terminal is not live")
        foreground = info.get("foreground")
        pid = info.get("pid")
        fg_pid = foreground.get("pid") if isinstance(foreground, dict) else None
        if any(type(p) is not int or p <= 1 for p in (pid, fg_pid)):
            raise ValueError("hc caller unverified: terminal process evidence unavailable")
        if pid not in parent_pids or fg_pid not in parent_pids:
            raise ValueError("hc caller unverified: terminal processes are not caller ancestors")
        return pid, fg_pid

    first = observe()
    if observe() != first:
        raise ValueError("hc caller unverified: terminal processes changed during verification")
    return {"verified": True, "method": "hc-foreground-ancestry",
            "server": server, "terminal_id": terminal,
            "owner": "hc:" + server + "#" + terminal}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["resolve", "prepare", "verify"])
    args = parser.parse_args()
    if args.action == "resolve":
        if os.environ.get("HC_TERMINAL_ID") and os.environ.get("HERDR_ENV") != "1":
            print(json.dumps(hc_identity(os.environ, ancestors())))
            return
        panes = inventory()
        pane = inherited(panes, os.environ, ancestors())
        if pane is None:
            session_id = os.environ.get("CODEX_SESSION_ID", "")
            match = resumed_session(panes, session_id, process)
            if match is None:
                raise ValueError("no verified caller; use prepare then verify in separate tool calls")
            pane, pids = match
            live, info = recheck(pane, pids)
            if resumed_session([live], session_id, lambda _: info) is None:
                raise ValueError("caller session changed during verification")
            emit(live, "foreground-resume-session")
            return
        emit(pane, "foreground-ancestry")
        return
    session_id = os.environ.get("CODEX_SESSION_ID", "")
    path = state_path(session_id)
    if args.action == "prepare":
        processes = {}
        for pane in inventory():
            if pane.get("agent") == "codex":
                info = process(pane)
                if codex_foreground(pane, info):
                    processes[pane["socket"] + "#" + pane["pane_id"]] = [
                        p["pid"] for p in info["foreground_processes"]]
        if not processes:
            raise ValueError("no live Codex foreground pane in running Herdr 1 sessions; "
                             "cannot prepare visual proof (Herdr 2/ACP chats are separate)")
        state = {"session_id": session_id, "created": time.time(),
                 "marker": "HERDR-CALLER-PROOF-" + secrets.token_hex(24), "processes": processes}
        # Private, atomic state, with no environment values or transcript.
        tmp = path.with_suffix("." + secrets.token_hex(8))
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump(state, stream)
        os.replace(tmp, path)
        print(state["marker"], flush=True)
        print("Display the marker above on its own line in assistant commentary BEFORE verify. "
              "Tool output alone may be hidden by the TUI. Then run verify in a separate "
              "tool call within 120 seconds. Do not copy this proof into another pane.")
        return
    state = json.loads(path.read_text())
    def read(pane):
        return run("herdr", "--session", pane["session"], "pane", "read", pane["pane_id"],
                   "--source", "recent-unwrapped", "--lines", "1000")
    pane, pids = challenge_match(inventory(), state, session_id, time.time(), read,
                               get_process=process)
    # Recheck live topology/processes after collecting the snapshots.
    recheck(pane, pids)
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
