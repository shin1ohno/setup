#!/usr/bin/env python3
"""mw_client.py — write and read a memory store over MCP streamable HTTP (stdlib only).

The TODO pipeline's records live in a memory store reached through an MCP server:
todo records (an approval) and append-only `todo-disposition` records (every other
decision). Until now only a model session could write them, because only the model
held an MCP client. Every deterministic surface — the tailnet approval desk, a sync
script, a cron job — needs the same three things: the streamable-HTTP session dance,
the record grammar, and a guard against writing the same decision twice. This module
is that one place, so a surface never re-implements the grammar and never talks to
Elasticsearch directly.

Transport. `initialize` -> keep the `mcp-session-id` header -> `notifications/initialized`
-> `tools/call`. Responses may be `application/json` or an SSE stream (`text/event-stream`,
one `data:` line per message), so both are parsed. Default endpoint
`http://127.0.0.1:8011/memory/mcp`: on the work box that path is the auth proxy, which
derives provenance from the connection itself, so a loopback caller needs no token and is
stamped as the machine (tool-output). The path matters — `/mcp` is a 404 there.

Record grammar (docs/todo-management.md "Dispositions"). A disposition is:

    todo-disposition <kind> key=<key> written_at=<ISO>[ until=<date>][ thread_key=<tk>]
    <one line of reason or title>

`written_at=` is written into the BODY on purpose: the reader (`todo_queue.py`
parse_disposition) prefers the in-body value, and the store nests its own timestamp
under `provenance`, where a body-less record would lose every latest-wins comparison.

Subcommands:
  browse --tags T [--limit N]        list records by exact tag match
  get --id ID                        one record
  remember --content-file F --tags a,b,c [--type fact]
  forget --id ID
  disposition --kind K --key K2 --source S [--until D] [--thread-key T]
              [--reason R] [--body-file F] [--announce A] [--extra k=v ...]
  todo --key K --source S --title T --close-condition C [--permalink P] [--due D]
       [--via V] [--announce A]
  probe                              initialize + tools/list, prints the tool names

Exit codes match todo_queue.py: 0 ok / 1 unexpected / 2 usage or unreachable path /
3 validation (one `<what>: <message>` line per violation on stderr) / 4 the server
returned something that is not JSON.

Same-decision guard: a write records `<kind>\t<key>` with a timestamp under
`<state-dir>/mw-client-recent.json` and refuses an identical pair inside
`--dedup-window` seconds (default 30) with exit 3. A double-tapped button, a retried
request and a re-run script therefore cost one record, not three. `--force` overrides.
"""

from __future__ import annotations

import argparse
import datetime as dt
import http.client
import json
import os
import re
import sys
import tempfile
import urllib.parse
from pathlib import Path

DEFAULT_URL = "http://127.0.0.1:8011/memory/mcp"
DEFAULT_TIMEOUT = 10.0
DEFAULT_DEDUP_WINDOW = 30
PROTOCOL_VERSION = "2025-03-26"
CLIENT_NAME = "mw_client"

DISPOSITION_KINDS = ("reject", "snooze", "never", "done", "expired", "revive", "approve")
KEY_RE = re.compile(r"\A(slack|notion|transcript|reminders|gtasks):[^\s]+\Z")
DATE_RE = re.compile(r"\A\d{4}-\d{2}-\d{2}\Z")
ISO_RE = re.compile(r"\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\Z")
# A body line may never start a second disposition record, and may never carry the
# marker lines the reader keys on. Free text from a browser reaches this module, so
# the check is on content, not on the caller.
FORBIDDEN_BODY_RE = re.compile(r"(?mi)^\s*(todo-disposition\s|key=|written_at=|until=|thread_key=|announce=)")

EXIT_OK, EXIT_ERROR, EXIT_USAGE, EXIT_VALIDATION, EXIT_JSON = 0, 1, 2, 3, 4


class ValidationError(Exception):
    def __init__(self, errors):
        super().__init__("\n".join(errors))
        self.errors = list(errors)


class TransportError(Exception):
    pass


class JsonError(Exception):
    pass


def utc_now_iso(now=None):
    if now:
        return now
    return (
        dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def _one_line(text):
    """Collapse a value to a single line. Newlines in a body would let free text forge
    a second record line, so they are folded rather than escaped."""
    return " ".join(str(text or "").split())


# --- record grammar ---------------------------------------------------------------


def disposition_content(kind, key, written_at, reason=None, until=None, thread_key=None, announce=None, extra=None, body=None):
    """The disposition record body. The `todo-disposition` line comes first (the base
    shape); optional fields sit on that line. Reason/title follows as one line."""
    head = f"todo-disposition {kind} key={key} written_at={written_at}"
    if until:
        head += f" until={until}"
    if thread_key:
        head += f" thread_key={thread_key}"
    if announce:
        head += f" announce={announce}"
    for k, v in (extra or {}).items():
        head += f" {k}={_one_line(v).replace(' ', '_')}"
    lines = [head]
    tail = _one_line(body if body is not None else (reason or ""))
    if tail:
        lines.append(tail)
    return "\n".join(lines) + "\n"


def todo_content(key, title, close_condition, permalink=None, due=None, announce=None, note=None):
    """An approval IS the todo record. `key=` first so dedup finds it; `announce=` next
    when the decision came from a surface that can be contradicted later."""
    lines = [f"key={key}"]
    if announce:
        lines.append(f"announce={announce}")
    lines.append(f"TODO (work): {_one_line(title)}")
    lines.append(f"完了条件: {_one_line(close_condition)}")
    if due:
        lines.append(f"期日: {due}")
    if permalink:
        lines.append(f"provenance: {permalink}")
    if note:
        lines.append(_one_line(note))
    return "\n".join(lines) + "\n"


def validate_key(key, where="key"):
    if not key or not KEY_RE.match(str(key)):
        return [f"{where}: {key!r} is not a canonical provenance key (slack:/notion:/transcript:/reminders:/gtasks:)"]
    return []


def validate_write(kind=None, key=None, until=None, written_at=None, body=None, thread_key=None, today=None, max_until_days=400):
    """Everything a surface can get wrong before a record reaches the store."""
    errors = []
    if kind is not None and kind not in DISPOSITION_KINDS:
        errors.append(f"kind: {kind!r} is not one of {'/'.join(DISPOSITION_KINDS)}")
    if key is not None:
        errors += validate_key(key)
    if thread_key:
        errors += validate_key(thread_key, where="thread_key")
    if written_at is not None and not ISO_RE.match(str(written_at)):
        errors.append(f"written_at: {written_at!r} is not YYYY-MM-DDTHH:MM:SSZ")
    if until is not None:
        if not DATE_RE.match(str(until)):
            errors.append(f"until: {until!r} is not YYYY-MM-DD")
        elif today is not None:
            try:
                delta = (dt.date.fromisoformat(str(until)) - today).days
            except ValueError:
                delta = None
            if delta is not None and delta > max_until_days:
                errors.append(f"until: {until} is {delta} days out (max {max_until_days}) — a typo would hide the candidate for years")
    if body:
        m = FORBIDDEN_BODY_RE.search(body)
        if m:
            errors.append(
                f"body: line starting {m.group(1).strip()!r} would be read as a record field — free text may not contain a marker line"
            )
    return errors


# --- transport --------------------------------------------------------------------


class McpClient:
    """One streamable-HTTP MCP session. Not thread-safe: make one per request."""

    def __init__(self, url=DEFAULT_URL, timeout=DEFAULT_TIMEOUT):
        parts = urllib.parse.urlsplit(url)
        if parts.scheme not in ("http", "https"):
            raise TransportError(f"unsupported scheme in {url!r}")
        self.url = url
        self.host = parts.hostname or "127.0.0.1"
        self.port = parts.port or (443 if parts.scheme == "https" else 80)
        self.path = parts.path or "/"
        self.https = parts.scheme == "https"
        self.timeout = timeout
        self.session_id = None
        self._id = 0
        self._initialized = False

    def _conn(self):
        cls = http.client.HTTPSConnection if self.https else http.client.HTTPConnection
        return cls(self.host, self.port, timeout=self.timeout)

    def _next_id(self):
        self._id += 1
        return self._id

    def _post(self, payload, expect_response=True):
        headers = {
            "content-type": "application/json",
            "accept": "application/json, text/event-stream",
        }
        if self.session_id:
            headers["mcp-session-id"] = self.session_id
        conn = self._conn()
        try:
            conn.request("POST", self.path, body=json.dumps(payload).encode("utf-8"), headers=headers)
            resp = conn.getresponse()
            raw = resp.read().decode("utf-8", errors="replace")
            sid = resp.getheader("mcp-session-id")
            if sid:
                self.session_id = sid
            if resp.status >= 400:
                raise TransportError(f"{self.url} returned HTTP {resp.status}: {raw[:200]}")
            if not expect_response:
                return None
            return _parse_body(raw)
        except (OSError, http.client.HTTPException) as exc:
            raise TransportError(f"{self.url}: {exc.__class__.__name__}: {exc}") from None
        finally:
            conn.close()

    def initialize(self):
        if self._initialized:
            return
        msg = self._post(
            {
                "jsonrpc": "2.0",
                "id": self._next_id(),
                "method": "initialize",
                "params": {
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": {"name": CLIENT_NAME, "version": "1"},
                },
            }
        )
        if "error" in (msg or {}):
            raise TransportError(f"initialize failed: {msg['error']}")
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"}, expect_response=False)
        self._initialized = True

    def call(self, name, arguments):
        self.initialize()
        msg = self._post(
            {"jsonrpc": "2.0", "id": self._next_id(), "method": "tools/call", "params": {"name": name, "arguments": arguments}}
        )
        if "error" in (msg or {}):
            raise TransportError(f"{name} failed: {msg['error']}")
        return (msg or {}).get("result", {})

    def tool_names(self):
        self.initialize()
        msg = self._post({"jsonrpc": "2.0", "id": self._next_id(), "method": "tools/list"})
        tools = ((msg or {}).get("result") or {}).get("tools") or []
        return [t.get("name") for t in tools]


def _parse_body(raw):
    """A response is either a JSON object or an SSE stream whose `data:` lines carry
    the messages. Return the first message that has an id (the reply to our request)."""
    text = raw.strip()
    if not text:
        return {}
    if text.startswith("{"):
        try:
            return json.loads(text)
        except json.JSONDecodeError as exc:
            raise JsonError(f"response is not JSON: {exc}: {text[:200]}") from None
    messages = []
    saw_data_line = False
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("data:"):
            continue
        saw_data_line = True
        chunk = line[5:].strip()
        if not chunk:
            continue
        try:
            messages.append(json.loads(chunk))
        except json.JSONDecodeError as exc:
            raise JsonError(f"SSE data line is not JSON: {exc}: {chunk[:200]}") from None
    if not saw_data_line:
        # Neither a JSON document nor an SSE stream. Returning {} here would make a
        # garbage response look like an empty success, which is the silent-failure
        # shape this whole module exists to avoid.
        raise JsonError(f"response is neither JSON nor an SSE stream: {text[:200]}")
    for msg in messages:
        if "id" in msg:
            return msg
    return messages[0] if messages else {}


def result_text(result):
    """MCP content blocks -> the text the tool printed."""
    out = []
    for block in (result or {}).get("content") or []:
        if isinstance(block, dict) and block.get("type") == "text":
            out.append(block.get("text") or "")
    return "\n".join(out)


def result_json(result):
    """The store's tools answer with a JSON document inside a text block."""
    text = result_text(result).strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def record_id(result):
    """The id of a just-written record, wherever the server put it."""
    doc = result_json(result)
    if isinstance(doc, dict):
        for field in ("id", "_id", "doc_id", "memory_id"):
            if doc.get(field):
                return str(doc[field])
        for nest in ("item", "memory", "result"):
            inner = doc.get(nest)
            if isinstance(inner, dict) and inner.get("id"):
                return str(inner["id"])
    m = re.search(r"\b([A-Za-z0-9_-]{16,})\b", result_text(result))
    return m.group(1) if m else None


# --- same-decision guard ----------------------------------------------------------


def _state_path(state_dir):
    return Path(state_dir) / "mw-client-recent.json"


def _write_atomic(path, text):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{p.name}.", suffix=".tmp", dir=str(p.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, p)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def check_and_record(state_dir, kind, key, window=DEFAULT_DEDUP_WINDOW, now=None, force=False):
    """Return None when the write may proceed, else the seconds since the twin write.
    Records the attempt when it proceeds. The file is small and self-pruning."""
    now_dt = dt.datetime.fromisoformat(utc_now_iso(now).replace("Z", "+00:00"))
    path = _state_path(state_dir)
    seen = {}
    try:
        seen = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(seen, dict):
            seen = {}
    except (OSError, json.JSONDecodeError):
        seen = {}
    slot = f"{kind}\t{key}"
    fresh = {}
    for k, v in seen.items():
        try:
            age = (now_dt - dt.datetime.fromisoformat(str(v).replace("Z", "+00:00"))).total_seconds()
        except (ValueError, TypeError):
            continue
        # age < 0 means a timestamp in the future. This file lives in a directory other
        # local processes can write, and a future stamp would keep `age < window` true
        # for as long as it says — a denial of service dressed as deduplication, with
        # the operator's decisions silently refused. Drop those entries as stale rather
        # than honouring them.
        if 0 <= age < max(window * 20, 600):
            fresh[k] = v
    if not force and slot in fresh:
        age = (now_dt - dt.datetime.fromisoformat(str(fresh[slot]).replace("Z", "+00:00"))).total_seconds()
        if 0 <= age < window:
            return round(age, 1)
    fresh[slot] = utc_now_iso(now)
    try:
        _write_atomic(path, json.dumps(fresh, separators=(",", ":")) + "\n")
    except OSError:
        pass  # the guard is best-effort; never block a decision on a full disk
    return None


# --- high-level writes ------------------------------------------------------------


def write_disposition(client, kind, key, source, written_at, reason=None, until=None, thread_key=None, announce=None, extra=None, body=None, today=None, dry_run=False):
    errors = validate_write(kind=kind, key=key, until=until, written_at=written_at, body=body or reason, thread_key=thread_key, today=today)
    if errors:
        raise ValidationError(errors)
    content = disposition_content(kind, key, written_at, reason=reason, until=until, thread_key=thread_key, announce=announce, extra=extra, body=body)
    tags = ["todo-disposition", kind] + ([source] if source else [])
    if dry_run:
        return {"dry_run": True, "content": content, "tags": tags}
    result = client.call("remember", {"content": content, "type": "fact", "tags": tags})
    return {"id": record_id(result), "content": content, "tags": tags}


def write_todo(client, key, source, title, close_condition, permalink=None, due=None, announce=None, via="via:desk", note=None, dry_run=False):
    errors = validate_write(key=key, body=f"{title}\n{close_condition}\n{note or ''}")
    if errors:
        raise ValidationError(errors)
    content = todo_content(key, title, close_condition, permalink=permalink, due=due, announce=announce, note=note)
    tags = ["todo"] + ([source] if source else []) + ([via] if via else [])
    if dry_run:
        return {"dry_run": True, "content": content, "tags": tags}
    result = client.call("remember", {"content": content, "type": "fact", "tags": tags})
    return {"id": record_id(result), "content": content, "tags": tags}


# --- CLI --------------------------------------------------------------------------


def build_parser():
    p = argparse.ArgumentParser(prog="mw_client.py", description=__doc__.splitlines()[0])
    p.add_argument("--url", default=os.environ.get("MW_CLIENT_URL", DEFAULT_URL))
    p.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)
    p.add_argument("--state-dir", default=str(Path.home() / ".claude" / "todo" / "tmp"))
    p.add_argument("--dedup-window", type=int, default=DEFAULT_DEDUP_WINDOW)
    p.add_argument("--force", action="store_true", help="write even if an identical decision was just written")
    p.add_argument("--dry-run", action="store_true", help="print what would be written; touch nothing")
    p.add_argument("--now", help="ISO8601Z override (tests)")
    p.add_argument("--today", help="YYYY-MM-DD override (tests)")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("probe", help="initialize + tools/list")

    b = sub.add_parser("browse", help="list records by exact tag")
    b.add_argument("--tags", required=True)
    b.add_argument("--limit", type=int, default=500)

    g = sub.add_parser("get", help="one record by id")
    g.add_argument("--id", required=True)

    r = sub.add_parser("remember", help="write a record verbatim from a file")
    r.add_argument("--content-file", required=True)
    r.add_argument("--tags", required=True)
    r.add_argument("--type", default="fact")

    f = sub.add_parser("forget", help="delete a record by id")
    f.add_argument("--id", required=True)

    d = sub.add_parser("disposition", help="write a todo-disposition record")
    d.add_argument("--kind", required=True)
    d.add_argument("--key", required=True)
    d.add_argument("--source", required=True)
    d.add_argument("--until")
    d.add_argument("--thread-key")
    d.add_argument("--announce")
    d.add_argument("--reason")
    d.add_argument("--body-file")

    t = sub.add_parser("todo", help="write a todo record (an approval)")
    t.add_argument("--key", required=True)
    t.add_argument("--source", required=True)
    t.add_argument("--title", required=True)
    t.add_argument("--close-condition", required=True)
    t.add_argument("--permalink")
    t.add_argument("--due")
    t.add_argument("--announce")
    t.add_argument("--via", default="via:desk")
    return p


def _read(path):
    try:
        return Path(path).read_text(encoding="utf-8")
    except OSError as exc:
        raise SystemExit(f"cannot read {path}: {exc}")


def main(argv=None):
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        return EXIT_USAGE if exc.code else EXIT_OK
    now = utc_now_iso(args.now)
    today = dt.date.fromisoformat(args.today) if args.today else dt.date.fromisoformat(now[:10])
    client = None
    try:
        if not args.dry_run:
            client = McpClient(args.url, timeout=args.timeout)

        if args.cmd == "probe":
            print(json.dumps({"url": args.url, "tools": client.tool_names()}, ensure_ascii=False))
            return EXIT_OK

        if args.cmd == "browse":
            res = client.call("browse", {"filters": {"tags": args.tags}, "limit": args.limit})
            print(result_text(res))
            return EXIT_OK

        if args.cmd == "get":
            print(result_text(client.call("get", {"id": args.id})))
            return EXIT_OK

        if args.cmd == "remember":
            content = _read(args.content_file)
            tags = [t for t in args.tags.split(",") if t]
            if args.dry_run:
                print(json.dumps({"dry_run": True, "tags": tags, "content": content}, ensure_ascii=False))
                return EXIT_OK
            res = client.call("remember", {"content": content, "type": args.type, "tags": tags})
            print(json.dumps({"id": record_id(res)}, ensure_ascii=False))
            return EXIT_OK

        if args.cmd == "forget":
            res = client.call("forget", {"id": args.id})
            print(json.dumps({"forgot": args.id, "text": result_text(res)[:200]}, ensure_ascii=False))
            return EXIT_OK

        if args.cmd in ("disposition", "todo"):
            kind = args.kind if args.cmd == "disposition" else "approve"
            busy = check_and_record(args.state_dir, kind, args.key, window=args.dedup_window, now=args.now, force=args.force or args.dry_run)
            if busy is not None:
                print(f"duplicate: {kind} {args.key} was written {busy}s ago (window {args.dedup_window}s); use --force to override", file=sys.stderr)
                return EXIT_VALIDATION
            if args.cmd == "disposition":
                out = write_disposition(
                    client, args.kind, args.key, args.source, now,
                    reason=args.reason, until=args.until, thread_key=args.thread_key,
                    announce=args.announce, body=_read(args.body_file) if args.body_file else None,
                    today=today, dry_run=args.dry_run,
                )
            else:
                out = write_todo(
                    client, args.key, args.source, args.title, args.close_condition,
                    permalink=args.permalink, due=args.due, announce=args.announce,
                    via=args.via, dry_run=args.dry_run,
                )
            print(json.dumps(out, ensure_ascii=False))
            return EXIT_OK

        parser.error(f"unknown subcommand {args.cmd}")
    except ValidationError as exc:
        for e in exc.errors:
            print(e, file=sys.stderr)
        return EXIT_VALIDATION
    except JsonError as exc:
        print(str(exc), file=sys.stderr)
        return EXIT_JSON
    except TransportError as exc:
        print(str(exc), file=sys.stderr)
        return EXIT_USAGE
    except SystemExit as exc:
        if isinstance(exc.code, str):
            print(exc.code, file=sys.stderr)
            return EXIT_USAGE
        return exc.code if isinstance(exc.code, int) else EXIT_USAGE
    except Exception as exc:  # noqa: BLE001 — last resort, keep the caller informed
        print(f"mw_client.py: unexpected error: {exc.__class__.__name__}: {exc}", file=sys.stderr)
        return EXIT_ERROR
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
