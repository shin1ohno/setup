"""Normalize Codex rollout records for indexing; archives retain the native JSONL.

Shared with the ccs client by cookbook placement, like session_redact.py. Only
response_item records supply messages: event_msg repeats their contents. Model
reasoning and injected developer/system context never become searchable text.
"""

from __future__ import annotations

import hashlib
import json

INTERACTIVE = frozenset({"codex-cli", "codex-vscode", "codex-appServer"})


def is_codex(entrypoint) -> bool:
    return isinstance(entrypoint, str) and entrypoint.startswith("codex-")


def text_content(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(b["text"] for b in content if isinstance(b, dict)
                         and b.get("type") in ("input_text", "output_text", "text")
                         and isinstance(b.get("text"), str))
    return ""


def normalize(rec: dict, *, position: int = 0, entrypoint=None, cwd=None) -> dict:
    """Return the common transcript representation, without changing the input."""
    kind, payload = rec.get("type"), rec.get("payload")
    if kind == "session-search-tombstone":
        return rec
    if not isinstance(payload, dict):
        return {"type": "system", "timestamp": rec.get("timestamp")}
    base = {"type": "system", "timestamp": rec.get("timestamp"), "cwd": cwd,
            "entrypoint": entrypoint}
    if kind == "session_meta":
        source = payload.get("source")
        source = source if isinstance(source, str) else "subagent"
        git = payload.get("git")
        base.update(cwd=payload.get("cwd"), entrypoint="codex-" + source,
                    version=payload.get("cli_version"),
                    gitBranch=git.get("branch") if isinstance(git, dict) else None)
        return base
    if kind == "turn_context":
        base["cwd"] = payload.get("cwd") or cwd
        return base
    if kind != "response_item":
        return base
    typ, role = payload.get("type"), payload.get("role")
    content = []
    if typ == "message" and role in ("user", "assistant"):
        if payload.get("channel") == "analysis":
            return base
        text = text_content(payload.get("content"))
        # These are synthetic user records, not a person's conversation.
        if text.lstrip().startswith(("# AGENTS.md instructions", "<environment_context>")):
            return base
        content = [{"type": "text", "text": text}]
    elif typ in ("function_call", "custom_tool_call"):
        role = "assistant"
        args = payload.get("arguments") if typ == "function_call" else payload.get("input")
        if not isinstance(args, str):
            args = json.dumps(args, ensure_ascii=False)
        content = [{"type": "tool_use", "name": payload.get("name") or typ,
                    "input": {"command": args}}]
    elif typ in ("function_call_output", "custom_tool_call_output"):
        role = "user"
        output = payload.get("output")
        if not isinstance(output, str):
            output = json.dumps(output, ensure_ascii=False)
        content = [{"type": "tool_result", "content": output}]
    else:
        return base
    # Some rollout items have null IDs. Position disambiguates identical items
    # while remaining stable on an ingest retry of the same segment.
    uid = payload.get("id")
    if not isinstance(uid, str) or not uid:
        uid = hashlib.sha256((str(position) + json.dumps(rec, sort_keys=True,
                                                       ensure_ascii=False)).encode()).hexdigest()
    base.update(type=role, uuid="codex-" + uid,
                message={"role": role, "id": uid, "content": content})
    return base
