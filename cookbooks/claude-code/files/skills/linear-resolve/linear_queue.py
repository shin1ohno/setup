#!/usr/bin/env python3
"""linear_queue.py — the deterministic half of the linear-resolve loop.

Pure functions over a JSON dump the SKILL fetched. This module never talks to
Linear, holds no credential, and makes no network call — the same split
todo_queue.py uses, for the same reason: the part that decides what the loop is
allowed to work on must be reviewable without reading a model transcript.

Input is `{"issues": [ ...Linear issue nodes... ]}` exactly as the GraphQL query
in SKILL.md returns it. Output is a single selection decision plus the reason
every other candidate was rejected, so a run log can show what it did NOT do.

Bot-authorship: the loop authenticates with the operator's PERSONAL API key, so
its own comments are authored by the operator's user id. Author id therefore
CANNOT distinguish the loop from the human — the same trap measured on GitHub,
where 170 issues over 77 days produced zero notifications because the bot wrote
as the owner. The only reliable signal is the marker the loop writes into its
own comment bodies, and it is matched as an EXACT substring of a fixed HTML
comment. setup#963 is the cautionary case: an extra UNANCHORED pattern
(`self-heal-(resolve|create)`) meant an owner GO that merely named the loop was
classified as a bot comment, permanently. There is exactly one pattern here.
"""

import argparse
import json
import re
import sys

BOT_MARKER = "<!-- linear-bot -->"
ATTEMPT_RE = re.compile(r"^linear-loop attempt (\d+)\b", re.M)
# The loop's terminal marker. Written into the comment that reports completion,
# alongside removing the agent label. Two mechanisms rather than one because the
# label removal is a mutation that can fail on a network blip: if the comment
# landed and the label removal did not, this marker still stops the loop from
# re-picking the issue every cycle until attempts run out.
DONE_RE = re.compile(r"^linear-loop done\b", re.M)

DEFAULTS = {
    "agent_label": "agent",
    "needs_human_label": "agent:needs-human",
    "max_attempts": 3,
}


def is_bot_comment(comment):
    """The loop's own comments carry the marker. Nothing else counts."""
    return BOT_MARKER in (comment.get("body") or "")


def label_names(issue):
    return {n.get("name") for n in (issue.get("labels") or {}).get("nodes", [])}


def comments(issue):
    return (issue.get("comments") or {}).get("nodes", []) or []


def attempts(issue):
    """How many times the loop has already worked this issue.

    Counted from the loop's own comments rather than an external store, so the
    count survives losing the host and needs no state file to reconcile.
    """
    n = 0
    for c in comments(issue):
        if not is_bot_comment(c):
            continue
        m = ATTEMPT_RE.search(c.get("body") or "")
        if m:
            n = max(n, int(m.group(1)))
    return n


def is_done(issue):
    """Has the loop already declared this issue finished?

    Deliberately revocable: `classify` treats a done issue as finished only
    while the operator has not spoken since. A terminal state the operator
    cannot reopen by commenting would rebuild the permanent lock that setup#963
    removed from the GitHub loop.
    """
    return any(is_bot_comment(c) and DONE_RE.search(c.get("body") or "") for c in comments(issue))


def owner_unblocked(issue, owner_id):
    """True when the operator has spoken after the loop last did.

    Mirrors self-heal-resolve's user-signal rule: a third party is ignored
    entirely, the loop never answers itself, and only an operator comment newer
    than the loop's newest comment re-opens a needs-human issue.
    """
    latest_owner = None
    latest_bot = None
    for c in comments(issue):
        created = c.get("createdAt")
        if not created:
            continue
        if is_bot_comment(c):
            if latest_bot is None or created > latest_bot:
                latest_bot = created
            continue
        # A non-bot comment counts only when the operator wrote it.
        if ((c.get("user") or {}).get("id")) != owner_id:
            continue
        if latest_owner is None or created > latest_owner:
            latest_owner = created
    if latest_owner is None:
        return False
    return latest_bot is None or latest_owner > latest_bot


def classify(issue, owner_id, cfg):
    """Return (actionable: bool, reason: str)."""
    labels = label_names(issue)
    if cfg["agent_label"] not in labels:
        return False, "no agent label"
    if attempts(issue) >= cfg["max_attempts"]:
        return False, f"attempts exhausted ({cfg['max_attempts']})"
    if is_done(issue):
        if not owner_unblocked(issue, owner_id):
            return False, "done, awaiting the operator"
        return True, "done but the operator replied"
    if cfg["needs_human_label"] in labels:
        if not owner_unblocked(issue, owner_id):
            return False, "needs-human, awaiting the operator"
        return True, "needs-human but the operator replied"
    return True, "open agent issue"


def select(dump, owner_id, cfg):
    """Pick exactly ONE issue: the least recently updated actionable one.

    One unit of work per run is the invariant every loop in this fleet holds;
    it bounds the blast radius of a bad run to a single issue.
    """
    decisions = []
    actionable = []
    for issue in dump.get("issues", []):
        ok, reason = classify(issue, owner_id, cfg)
        decisions.append(
            {"identifier": issue.get("identifier"), "actionable": ok, "reason": reason}
        )
        if ok:
            actionable.append(issue)
    actionable.sort(key=lambda i: i.get("updatedAt") or "")
    picked = actionable[0] if actionable else None
    return {
        "picked": (
            {
                "id": picked.get("id"),
                "identifier": picked.get("identifier"),
                "title": picked.get("title"),
                "attempt": attempts(picked) + 1,
            }
            if picked
            else None
        ),
        "considered": len(decisions),
        "actionable": len(actionable),
        "decisions": decisions,
    }


def load_cfg(args):
    cfg = dict(DEFAULTS)
    for k in ("agent_label", "needs_human_label"):
        v = getattr(args, k, None)
        if v:
            cfg[k] = v
    if getattr(args, "max_attempts", None):
        cfg["max_attempts"] = args.max_attempts
    return cfg


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("command", choices=["select", "attempts"])
    p.add_argument("--dump", required=True, help="path to the issues JSON, or - for stdin")
    p.add_argument("--owner-id", required=True, help="the operator's Linear user id")
    p.add_argument("--agent-label")
    p.add_argument("--needs-human-label")
    p.add_argument("--max-attempts", type=int)
    args = p.parse_args(argv)

    raw = sys.stdin.read() if args.dump == "-" else open(args.dump, encoding="utf-8").read()
    dump = json.loads(raw)
    cfg = load_cfg(args)

    if args.command == "select":
        print(json.dumps(select(dump, args.owner_id, cfg), ensure_ascii=False, indent=2))
        return 0
    for issue in dump.get("issues", []):
        print(f"{issue.get('identifier')}\t{attempts(issue)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
