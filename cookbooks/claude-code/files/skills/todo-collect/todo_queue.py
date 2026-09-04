#!/usr/bin/env python3
"""todo_queue.py — queue helper for the /todo-collect pipeline (stdlib only).

Owns the machine-readable half of ~/.claude/todo: the O(open) approval queue
`candidates.jsonl` (one meta line, then one candidate per line), the write-once
`runs/` history layout, the 1-line-per-run `ledger.md` index header, and the
on-demand `summary` view. Design of record: docs/todo-management.md ("Queue",
"Dispositions", "Run logs and index", "Aging").

Why Python and not a sibling of remind_sync.rb: the headless runner on the
always-on work box executes this from a systemd user unit whose PATH resolves
/usr/bin/python3 but no ruby (rbenv shims are an interactive-shell thing).
Everything here is stdlib, so /usr/bin/python3 3.x is enough.

Subcommands (Phase 1):
  init                    idempotent: runs/ + tmp/, legacy ledger -> runs/0000-legacy-*,
                          3-line index, meta-only candidates.jsonl
  validate --sweep P      3-valued enum contract of a sweep.json
  validate --queue P      same for a candidates.jsonl
  filter   --sweep P --run RUN_TS [--prev Q] [--config C] [--out Q] [--run-log L]
                          deterministic queue regeneration (dedup -> disposition ->
                          snooze -> aging -> ttl); prints the meta + per-key report
  summary  [--json]       20-line state view; never fails on a missing file

Exit codes: 0 ok · 1 unexpected error · 2 usage / unreadable path · 3 validation
failure (one `<file>: <path>: <message>` line per violation on stderr) · 4 input
is not valid JSON.

The queue is a derived VIEW, not a store of truth: a candidate row is a raw
capture that has not been approved yet, and every disposition (approve, reject,
snooze, never, done, expired, revive) lives in the memory store as an
append-only record. This helper only reads those records (handed over in
sweep.json) and never talks to the store itself.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import tempfile
from pathlib import Path

SCHEMA_VERSION = 1
SOURCE_STATUSES = ("swept", "unswept", "truncated")
ENUM_STATES = ("complete", "truncated", "unreached")
HIDE_KINDS = ("reject", "never", "done")
CANON_PREFIXES = ("slack:", "notion:", "transcript:", "reminders:", "gtasks:")
DEFAULT_QUEUE_CONFIG = {"ttl_days": 21, "dm_per_run_max": 10}
INDEX_HEADER = (
    "# TODO loop index — 1 line per run, written by the runner (the model never writes here)",
    "# <utc> | <loop> | <run id> | ok|fail(<class>) | <summary> | <run log path>",
)

EXIT_OK, EXIT_ERROR, EXIT_USAGE, EXIT_VALIDATION, EXIT_JSON = 0, 1, 2, 3, 4

SLACK_PERMALINK_RE = re.compile(
    r"https?://[^/\s]+/archives/([A-Za-z0-9]+)/p(\d{10})(\d{6})(?:\?([^\s#]*))?"
)
THREAD_TS_RE = re.compile(r"thread_ts=(\d+\.\d+)")
# A Notion id is 32 hex chars, either compact or as a dashed UUID. The lookarounds
# stop a run like "v0-3bf7…" from matching one character too early once the dash
# is gone, and the dashed form is normalised first so both spellings agree.
UUID_DASHED_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
HEX32_RE = re.compile(r"(?<![0-9a-fA-F])[0-9a-fA-F]{32}(?![0-9a-fA-F])")
DISPOSITION_RE = re.compile(r"^todo-disposition\s+(\S+)\s+key=(\S+)(.*)$")
KEY_LINE_RE = re.compile(r"(?m)^key=(\S+)")
DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}")


class ValidationError(Exception):
    def __init__(self, errors):
        super().__init__("\n".join(errors))
        self.errors = list(errors)


class JsonError(Exception):
    pass


# --- time helpers -------------------------------------------------------------


def utc_now_iso(now=None):
    if now:
        return now
    return (
        dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def today_from(today=None, now=None):
    if today:
        return dt.date.fromisoformat(today)
    if now:
        return dt.date.fromisoformat(str(now)[:10])
    return dt.datetime.now(dt.timezone.utc).date()


def parse_date(value):
    """First 10 chars of an ISO timestamp -> date, or None. The calendar day in the
    timestamp's own offset is what a human reads as 'the message date', which is what
    aging is about."""
    if not value:
        return None
    s = str(value).strip()
    if len(s) < 10:
        return None
    try:
        return dt.date.fromisoformat(s[:10])
    except ValueError:
        return None


# --- key normalization ----------------------------------------------------------


def slack_key_from_permalink(url):
    m = SLACK_PERMALINK_RE.search(url or "")
    if not m:
        return None, None
    channel, sec, us, query = m.group(1), m.group(2), m.group(3), m.group(4) or ""
    key = f"slack:{channel}/{sec}.{us}"
    tm = THREAD_TS_RE.search(query)
    thread_key = f"slack:{channel}/{tm.group(1)}" if tm else key
    return key, thread_key


def _notion_ids(text):
    compact = UUID_DASHED_RE.sub(lambda m: m.group(0).replace("-", ""), text or "")
    return [i.lower() for i in HEX32_RE.findall(compact)]


def notion_key_from_permalink(url, idx=None):
    url = url or ""
    frag = url.split("#", 1)[1] if "#" in url else ""
    base = url.split("#", 1)[0]
    ids = _notion_ids(base)
    if not ids:
        return None, None
    page = ids[0]
    anchors = _notion_ids(frag)
    anchor = anchors[0] if anchors else str(idx if idx is not None else 0)
    return f"notion:{page}#{anchor}", f"notion:{page}"


def canonical_key(item):
    """Return (key, thread_key) or (None, None) when nothing canonical can be derived."""
    key = item.get("key")
    tk = item.get("thread_key")
    if isinstance(key, str) and key.startswith(CANON_PREFIXES):
        return key, (tk if isinstance(tk, str) and tk else key)
    permalink = item.get("permalink") or ""
    if "/archives/" in permalink:
        k, t = slack_key_from_permalink(permalink)
        if k:
            return k, (tk or t)
    if "notion" in permalink:
        k, t = notion_key_from_permalink(permalink, item.get("idx"))
        if k:
            return k, (tk or t)
    return None, None


# --- validation ------------------------------------------------------------------


def _remaining_ok(v):
    return (isinstance(v, int) and not isinstance(v, bool) and v >= 0) or v == "unknown"


def _reason_ok(v):
    return isinstance(v, str) and v.strip() != ""


def validate_sources(sources, where, errors):
    if not isinstance(sources, list):
        errors.append(f"{where}: sources: must be a list")
        return
    for i, s in enumerate(sources):
        p = f"{where}: sources[{i}]"
        if not isinstance(s, dict):
            errors.append(f"{p}: must be an object")
            continue
        if not isinstance(s.get("name"), str) or not s.get("name"):
            errors.append(f"{p}.name: required")
        status = s.get("status")
        if status not in SOURCE_STATUSES:
            errors.append(f"{p}.status: must be one of {'|'.join(SOURCE_STATUSES)}, got {status!r}")
            continue
        if status == "truncated" and not _remaining_ok(s.get("remaining")):
            errors.append(f"{p}.remaining: required for truncated (int >= 0 or \"unknown\")")
        if status == "unswept" and not _reason_ok(s.get("reason")):
            errors.append(f"{p}.reason: required for unswept")


def validate_enum(env, where, errors):
    if not isinstance(env, dict):
        errors.append(f"{where}: must be an object")
        return
    state = env.get("state")
    if state not in ENUM_STATES:
        errors.append(f"{where}.state: must be one of {'|'.join(ENUM_STATES)}, got {state!r}")
        return
    if state == "truncated" and not _remaining_ok(env.get("remaining")):
        errors.append(f"{where}.remaining: required for truncated (int >= 0 or \"unknown\")")
    if state == "unreached" and not _reason_ok(env.get("reason")):
        errors.append(f"{where}.reason: required for unreached")


def envelope_or_default(doc, name):
    env = doc.get(name)
    if env is None:
        return {
            "enum": {
                "state": "unreached",
                "reason": f"{name} envelope absent from sweep.json",
                "total": None,
                "returned": 0,
                "remaining": None,
            },
            "records": [],
        }
    return env


def validate_sweep(doc, run=None, where="sweep.json"):
    errors = []
    if not isinstance(doc, dict):
        return [f"{where}: top level must be an object"]
    if run and doc.get("run") not in (None, run):
        errors.append(f"{where}: run: {doc.get('run')!r} != --run {run!r}")
    validate_sources(doc.get("sources", []), where, errors)
    for name in ("todos", "dispositions"):
        env = envelope_or_default(doc, name)
        if not isinstance(env, dict):
            errors.append(f"{where}: {name}: must be an object")
            continue
        validate_enum(env.get("enum"), f"{where}: {name}.enum", errors)
        if not isinstance(env.get("records", []), list):
            errors.append(f"{where}: {name}.records: must be a list")
    items = doc.get("items", [])
    if not isinstance(items, list):
        errors.append(f"{where}: items: must be a list")
        items = []
    for i, it in enumerate(items):
        p = f"{where}: items[{i}]"
        if not isinstance(it, dict):
            errors.append(f"{p}: must be an object")
            continue
        for field in ("source", "title"):
            if not isinstance(it.get(field), str) or not it.get(field):
                errors.append(f"{p}.{field}: required")
        if it.get("class") not in ("explicit", "inferred"):
            errors.append(f"{p}.class: must be explicit|inferred, got {it.get('class')!r}")
        key, _ = canonical_key(it)
        if key is None:
            errors.append(f"{p}: needs a canonical key ({'|'.join(CANON_PREFIXES)}) or a Slack/Notion permalink")
    return errors


def validate_queue_lines(meta, rows, where="candidates.jsonl"):
    errors = []
    if not isinstance(meta, dict) or meta.get("type") != "meta":
        return [f"{where}: line 1 must be the meta object"]
    if meta.get("schema") != SCHEMA_VERSION:
        errors.append(f"{where}: meta.schema: expected {SCHEMA_VERSION}, got {meta.get('schema')!r}")
    if not isinstance(meta.get("run"), str) or not meta.get("run"):
        errors.append(f"{where}: meta.run: required")
    validate_sources(meta.get("sources", []), where, errors)
    validate_enum(meta.get("dispositions_enum"), f"{where}: meta.dispositions_enum", errors)
    validate_enum(meta.get("todos_enum"), f"{where}: meta.todos_enum", errors)
    for i, r in enumerate(rows, start=2):
        if not isinstance(r, dict) or r.get("type") != "candidate":
            errors.append(f"{where}: line {i}: must be a candidate row")
            continue
        if not isinstance(r.get("key"), str) or not r.get("key").startswith(CANON_PREFIXES):
            errors.append(f"{where}: line {i}: key must be canonical")
    return errors


# --- dispositions -------------------------------------------------------------------


def parse_disposition(record):
    """Records are memory-store facts whose first line is
    `todo-disposition <kind> key=<key> written_at=<ISO>[ until=<date>][ thread_key=<tk>][ announce=<c>/<ts>]`.
    Anything else is ignored (None)."""
    content = record.get("content") if isinstance(record, dict) else None
    if not isinstance(content, str):
        return None
    first = content.strip().splitlines()[0] if content.strip() else ""
    m = DISPOSITION_RE.match(first.strip())
    if not m:
        return None
    kind, key, rest = m.group(1), m.group(2), m.group(3)
    fields = dict(re.findall(r"(\w+)=(\S+)", rest))
    return {
        "kind": kind,
        "key": key,
        "written_at": fields.get("written_at") or record.get("created_at") or record.get("written_at") or "",
        "until": fields.get("until"),
        "thread_key": fields.get("thread_key"),
        "announce": fields.get("announce"),
        "id": record.get("id"),
    }


def latest_dispositions(records):
    """(by_key, by_thread) — latest record per key / per thread_key, written_at wins."""
    by_key, by_thread = {}, {}
    for rec in records or []:
        d = parse_disposition(rec)
        if d is None:
            continue
        cur = by_key.get(d["key"])
        if cur is None or d["written_at"] >= cur["written_at"]:
            by_key[d["key"]] = d
        if d["thread_key"]:
            cur = by_thread.get(d["thread_key"])
            if cur is None or d["written_at"] >= cur["written_at"]:
                by_thread[d["thread_key"]] = d
    return by_key, by_thread


def existing_todo_keys(records):
    keys = set()
    for rec in records or []:
        content = rec.get("content") if isinstance(rec, dict) else None
        if isinstance(content, str):
            keys.update(KEY_LINE_RE.findall(content))
    return keys


# --- filter ---------------------------------------------------------------------------


def normalize_source_meta(s):
    return {
        "name": s.get("name"),
        "class": s.get("class"),
        "status": s.get("status"),
        "count": s.get("count"),
        "remaining": s.get("remaining"),
        "reason": s.get("reason"),
    }


def empty_meta(run, now, today, reason):
    env = {"state": "unreached", "reason": reason, "total": None, "returned": 0, "remaining": None}
    return {
        "type": "meta",
        "schema": SCHEMA_VERSION,
        "run": run,
        "generated_at": now,
        "today": today.isoformat(),
        "open": 0,
        "needs_review": 0,
        "aged_out": 0,
        "deduped": 0,
        "rejected_hidden": 0,
        "snoozed_hidden": 0,
        "expired": 0,
        "announced": 0,
        "filters_skipped": [],
        "dispositions_enum": dict(env),
        "todos_enum": dict(env),
        "sources": [],
        "ttl_days": DEFAULT_QUEUE_CONFIG["ttl_days"],
        "expired_keys": [],
        "origin_ts_missing": [],
    }


def load_config(path):
    if path is None:
        return {"queue": dict(DEFAULT_QUEUE_CONFIG), "sources": []}
    p = Path(path)
    if p.suffix in (".yaml", ".yml"):
        try:
            import yaml  # type: ignore
        except ImportError as exc:
            raise SystemExit(f"config must be JSON (PyYAML not available for {p}): {exc}") from None
        with p.open(encoding="utf-8") as fh:
            cfg = yaml.safe_load(fh) or {}
    else:
        cfg = load_json(p)
    if not isinstance(cfg, dict):
        raise JsonError(f"{p}: config must be an object")
    queue = dict(DEFAULT_QUEUE_CONFIG)
    queue.update(cfg.get("queue") or {})
    return {"queue": queue, "sources": cfg.get("sources") or []}


def filter_queue(prev_rows, sweep, config, run, today, now):
    """Pure function. Returns (meta, rows, report)."""
    ttl_days = int(config["queue"].get("ttl_days", DEFAULT_QUEUE_CONFIG["ttl_days"]))
    sources_cfg = {s.get("name"): s for s in config.get("sources", []) if isinstance(s, dict)}
    prev_by_key = {r.get("key"): r for r in prev_rows if isinstance(r, dict) and r.get("type") == "candidate"}

    todos_env = envelope_or_default(sweep, "todos")
    disp_env = envelope_or_default(sweep, "dispositions")
    existing = existing_todo_keys(todos_env.get("records"))
    disp_active = disp_env["enum"].get("state") == "complete"
    by_key, by_thread = latest_dispositions(disp_env.get("records")) if disp_active else ({}, {})

    report = {
        "aged_out_keys": [],
        "deduped_keys": [],
        "hidden": [],
        "expired_keys": [],
        "origin_ts_missing": [],
    }
    rows = []
    seen = set()
    counts = {"deduped": 0, "rejected_hidden": 0, "snoozed_hidden": 0, "aged_out": 0, "expired": 0}

    for item in sweep.get("items", []):
        key, thread_key = canonical_key(item)
        if key is None or key in seen:
            if key is not None:
                counts["deduped"] += 1
                report["deduped_keys"].append(key)
            continue
        seen.add(key)
        source = item.get("source")
        klass = item.get("class")

        if key in existing:
            counts["deduped"] += 1
            report["deduped_keys"].append(key)
            continue

        snooze_wake = None
        if disp_active:
            d = by_key.get(key)
            td = by_thread.get(thread_key)
            if d and d["kind"] in HIDE_KINDS:
                counts["rejected_hidden"] += 1
                report["hidden"].append({"key": key, "kind": d["kind"], "written_at": d["written_at"]})
                continue
            if td and td["kind"] in HIDE_KINDS and (d is None or td["written_at"] >= d["written_at"]):
                counts["rejected_hidden"] += 1
                report["hidden"].append({"key": key, "kind": f"{td['kind']}-thread", "written_at": td["written_at"]})
                continue
            if d and d["kind"] == "snooze":
                until = parse_date(d["until"])
                if until and until >= today:
                    counts["snoozed_hidden"] += 1
                    report["hidden"].append({"key": key, "kind": "snooze", "until": until.isoformat()})
                    continue
                snooze_wake = until.isoformat() if until else None

        origin = parse_date(item.get("origin_ts"))
        src_cfg = sources_cfg.get(source, {})
        max_age = src_cfg.get("max_age_days")
        if klass == "inferred" and max_age is not None:
            if origin is None:
                report["origin_ts_missing"].append(key)
            elif (today - origin).days > int(max_age):
                counts["aged_out"] += 1
                report["aged_out_keys"].append(
                    {"key": key, "source": source, "origin_ts": item.get("origin_ts"), "age_days": (today - origin).days}
                )
                continue

        prev = prev_by_key.get(key, {})
        first_seen = prev.get("first_seen") or today.isoformat()
        fs = parse_date(first_seen) or today
        if (today - fs).days > ttl_days:
            counts["expired"] += 1
            report["expired_keys"].append({"key": key, "first_seen": first_seen, "source": source})
            continue

        state = prev.get("state") if prev.get("state") in ("open", "needs_review") else "open"
        rows.append(
            {
                "type": "candidate",
                "key": key,
                "thread_key": thread_key,
                "source": source,
                "class": klass,
                "title": item.get("title"),
                "permalink": item.get("permalink"),
                "origin_ts": item.get("origin_ts"),
                "due": item.get("due"),
                "draft_close_condition": item.get("draft_close_condition"),
                "confidence": item.get("confidence"),
                "first_seen": first_seen,
                "announce": prev.get("announce"),
                "snooze_wake": snooze_wake,
                "state": state,
            }
        )

    rows.sort(key=lambda r: ((r.get("origin_ts") or ""), r["key"]))
    meta = empty_meta(run, now, today, reason="")
    meta.update(
        {
            "open": sum(1 for r in rows if r["state"] == "open"),
            "needs_review": sum(1 for r in rows if r["state"] == "needs_review"),
            "aged_out": counts["aged_out"],
            "deduped": counts["deduped"],
            "rejected_hidden": counts["rejected_hidden"],
            "snoozed_hidden": counts["snoozed_hidden"],
            "expired": counts["expired"],
            "announced": sum(1 for r in rows if r.get("announce")),
            "filters_skipped": [] if disp_active else ["disposition", "snooze"],
            "dispositions_enum": dict(disp_env["enum"]),
            "todos_enum": dict(todos_env["enum"]),
            "sources": [normalize_source_meta(s) for s in sweep.get("sources", [])],
            "ttl_days": ttl_days,
            "expired_keys": [e["key"] for e in report["expired_keys"]],
            "origin_ts_missing": list(report["origin_ts_missing"]),
        }
    )
    return meta, rows, report


# --- file I/O -----------------------------------------------------------------------


def load_json(path):
    try:
        with Path(path).open(encoding="utf-8") as fh:
            return json.load(fh)
    except json.JSONDecodeError as exc:
        raise JsonError(f"{path}: invalid JSON: {exc}") from None


def read_queue(path):
    """-> (meta, rows). A missing file is an empty queue; a broken line raises JsonError."""
    p = Path(path)
    if not p.exists():
        return None, []
    meta, rows = None, []
    with p.open(encoding="utf-8") as fh:
        for n, line in enumerate(fh, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as exc:
                raise JsonError(f"{path}: line {n}: invalid JSON: {exc}") from None
            if n == 1 and isinstance(obj, dict) and obj.get("type") == "meta":
                meta = obj
            else:
                rows.append(obj)
    return meta, rows


def dumps(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def write_atomic(path, text):
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


def write_queue(path, meta, rows):
    write_atomic(path, "".join(dumps(x) + "\n" for x in [meta] + rows))


def append_run_log(path, run, meta, report):
    lines = [f"### queue filter ({run})", ""]
    lines.append(
        f"- open {meta['open']} / needs_review {meta['needs_review']} / aged_out {meta['aged_out']} / "
        f"deduped {meta['deduped']} / hidden {meta['rejected_hidden'] + meta['snoozed_hidden']} / expired {meta['expired']}"
    )
    if meta["filters_skipped"]:
        lines.append(
            f"- disposition filters NOT applied ({', '.join(meta['filters_skipped'])}): "
            f"dispositions enum state={meta['dispositions_enum'].get('state')} "
            f"reason={meta['dispositions_enum'].get('reason')}"
        )
    for e in report["aged_out_keys"]:
        lines.append(f"- aged-out {e['key']} ({e['source']}, origin {e['origin_ts']}, {e['age_days']} days)")
    for e in report["expired_keys"]:
        lines.append(f"- expired {e['key']} ({e['source']}, first_seen {e['first_seen']})")
    for k in report["deduped_keys"]:
        lines.append(f"- deduped {k}")
    for h in report["hidden"]:
        extra = h.get("until") or h.get("written_at") or ""
        lines.append(f"- hidden {h['key']} ({h['kind']} {extra})".rstrip())
    for k in report["origin_ts_missing"]:
        lines.append(f"- origin_ts missing (kept, not aged) {k}")
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("a", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n\n")


# --- subcommands ------------------------------------------------------------------------


def cmd_init(todo_dir, now, today):
    todo_dir = Path(todo_dir)
    runs = todo_dir / "runs"
    runs.mkdir(parents=True, exist_ok=True)
    (todo_dir / "tmp").mkdir(exist_ok=True)
    created, migrated, legacy = [], False, None

    ledger = todo_dir / "ledger.md"
    if ledger.exists():
        text = ledger.read_text(encoding="utf-8", errors="replace")
        if re.search(r"(?m)^## ", text):
            heading_dates = sorted(
                set(DATE_RE.findall("\n".join(l for l in text.splitlines() if l.startswith("## "))))
            )
            dates = heading_dates or sorted(set(DATE_RE.findall(text)))
            if dates:
                first, last = dates[0], dates[-1]
            else:
                first = last = dt.datetime.fromtimestamp(ledger.stat().st_mtime, dt.timezone.utc).date().isoformat()
            legacy = runs / f"0000-legacy-ledger-{first}_{last}.md"
            n = 2
            while legacy.exists():
                legacy = runs / f"0000-legacy-ledger-{first}_{last}-{n}.md"
                n += 1
            os.replace(ledger, legacy)
            migrated = True

    if not ledger.exists():
        target = legacy.name if legacy else "(none)"
        lines = list(INDEX_HEADER) + [f"{now} | migrate | - | ok | legacy ledger -> runs/{target} | -"]
        write_atomic(ledger, "\n".join(lines) + "\n")
        created.append("ledger.md")

    queue = todo_dir / "candidates.jsonl"
    if not queue.exists():
        write_queue(queue, empty_meta("init", now, today, reason="init"), [])
        created.append("candidates.jsonl")

    print(dumps({"migrated": migrated, "legacy": str(legacy) if legacy else None, "created": created}))
    return EXIT_OK


def cmd_validate(args):
    errors = []
    if args.sweep:
        errors += validate_sweep(load_json(args.sweep), run=args.run, where=str(args.sweep))
    if args.queue:
        meta, rows = read_queue(args.queue)
        if meta is None and not rows:
            errors.append(f"{args.queue}: file missing or empty")
        else:
            errors += validate_queue_lines(meta, rows, where=str(args.queue))
            if args.run and meta and meta.get("run") != args.run:
                errors.append(f"{args.queue}: meta.run {meta.get('run')!r} != --run {args.run!r}")
    if errors:
        raise ValidationError(errors)
    print(dumps({"ok": True}))
    return EXIT_OK


def cmd_filter(args, todo_dir, now, today):
    todo_dir = Path(todo_dir)
    sweep = load_json(args.sweep)
    errors = validate_sweep(sweep, run=args.run, where=str(args.sweep))
    if errors:
        raise ValidationError(errors)
    prev_path = Path(args.prev) if args.prev else todo_dir / "candidates.jsonl"
    try:
        _, prev_rows = read_queue(prev_path)
    except JsonError as exc:
        print(f"WARN: previous queue unreadable, treating as empty: {exc}", file=sys.stderr)
        prev_rows = []
    config_path = args.config
    if config_path is None:
        candidate = todo_dir / "tmp" / f"{args.run}-config.json"
        config_path = str(candidate) if candidate.exists() else None
    config = load_config(config_path)
    meta, rows, report = filter_queue(prev_rows, sweep, config, args.run, today, now)
    out = Path(args.out) if args.out else todo_dir / "candidates.jsonl"
    write_queue(out, meta, rows)
    if args.run_log:
        append_run_log(args.run_log, args.run, meta, report)
    result = dict(meta)
    result.update(report)
    result["out"] = str(out)
    print(dumps(result))
    return EXIT_OK


def _age_days(iso, today):
    d = parse_date(iso)
    return (today - d).days if d else None


def _read_text(path):
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None


def build_summary(todo_dir, logs_dir, today, now_dt):
    todo_dir = Path(todo_dir)
    logs_dir = Path(logs_dir)
    out = {"queue": None, "sources": [], "stores": None, "prs": None, "loops": {}, "stale": []}
    lines = []

    try:
        meta, rows = read_queue(todo_dir / "candidates.jsonl")
    except JsonError as exc:
        meta, rows = None, []
        lines.append(f"queue: UNREADABLE ({exc})")
    if meta:
        ages = [a for a in (_age_days(r.get("first_seen"), today) for r in rows) if a is not None]
        oldest = max(ages) if ages else 0
        out["queue"] = {
            "run": meta.get("run"),
            "open": meta.get("open"),
            "needs_review": meta.get("needs_review"),
            "oldest_days": oldest,
            "aged_out": meta.get("aged_out"),
            "hidden": (meta.get("rejected_hidden") or 0) + (meta.get("snoozed_hidden") or 0),
            "expired": meta.get("expired"),
            "generated_at": meta.get("generated_at"),
        }
        lines.append(
            f"queue: open {meta.get('open')} (needs_review {meta.get('needs_review')}) oldest {oldest}d "
            f"run {meta.get('run')} aged_out {meta.get('aged_out')} hidden {out['queue']['hidden']} expired {meta.get('expired')}"
        )
        de = meta.get("dispositions_enum") or {}
        te = meta.get("todos_enum") or {}
        lines.append(
            f"dispositions: {de.get('state')} total {de.get('total')} returned {de.get('returned')} "
            f"remaining {de.get('remaining')} {de.get('reason') or ''}".rstrip()
        )
        lines.append(f"todos: {te.get('state')} total {te.get('total')} returned {te.get('returned')}")
        for s in (meta.get("sources") or [])[:8]:
            out["sources"].append(s)
            lines.append(
                f"source {s.get('name')}: {s.get('status')} count {s.get('count') if s.get('count') is not None else '-'} "
                f"remaining {s.get('remaining') if s.get('remaining') is not None else '-'} {s.get('reason') or ''}".rstrip()
            )
        if meta.get("filters_skipped"):
            lines.append(f"filters skipped: {', '.join(meta['filters_skipped'])}")
    elif not lines:
        lines.append("queue: no data (candidates.jsonl absent — run init)")

    stores_text = _read_text(todo_dir / "stores.json")
    if stores_text:
        try:
            stores = json.loads(stores_text)
            out["stores"] = stores
            parts = []
            for name, st in (stores.get("stores") or {}).items():
                if isinstance(st, dict):
                    parts.append(f"{name}={st.get('state')}:{st.get('open') if st.get('open') is not None else '-'}")
            lines.append(f"stores ({stores.get('run')}): {' '.join(parts) or 'empty'} air_pending_forget {stores.get('air_pending_forget', '-')}")
        except json.JSONDecodeError:
            lines.append("stores: UNREADABLE")
    else:
        lines.append("stores: no data")

    prs_text = _read_text(todo_dir / "prs.json")
    if prs_text:
        try:
            prs = json.loads(prs_text)
            out["prs"] = prs
            if prs.get("prs") is None:
                lines.append(f"prs: fetch failed ({prs.get('error')})")
            else:
                for pr in prs["prs"][:6]:
                    age = _age_days(pr.get("createdAt"), today)
                    lines.append(
                        f"pr {pr.get('repo')}#{pr.get('number')} {pr.get('mergeStateStatus')} {age if age is not None else '-'}d {pr.get('headRefName')}"
                    )
                if not prs["prs"]:
                    lines.append("prs: none open")
        except json.JSONDecodeError:
            lines.append("prs: UNREADABLE")
    else:
        lines.append("prs: no data")

    disabled = [
        n
        for n in ("todo-loops.DISABLED", "todo-collect.DISABLED", "todo-reconcile.DISABLED")
        if (todo_dir.parent / n).exists()
    ]
    for loop in ("todo-collect", "todo-reconcile"):
        last_text = _read_text(logs_dir / f"{loop}.last")
        last = last_text.strip() if last_text else None
        hours = None
        if last:
            try:
                last_dt = dt.datetime.fromisoformat(last.replace("Z", "+00:00"))
                hours = round((now_dt - last_dt).total_seconds() / 3600, 1)
            except ValueError:
                hours = None
        out["loops"][loop] = {"last": last, "hours_ago": hours}
        lines.append(f"loop {loop}: last ok {last or 'never'}{f' ({hours}h ago)' if hours is not None else ''}")
        if loop == "todo-collect" and hours is not None and hours > 30:
            out["stale"].append(loop)
    lines.append(f"disabled: {', '.join(disabled) if disabled else 'none'}")
    if out["stale"]:
        lines.append(f"stale: {', '.join(out['stale'])} (> 30h since last ok run — treat the queue as stopped)")
    return out, lines[:20]


def cmd_summary(args, todo_dir, today, now_dt):
    logs_dir = args.logs or str(Path(todo_dir).parent / "logs")
    out, lines = build_summary(todo_dir, logs_dir, today, now_dt)
    if args.json:
        print(dumps(out))
    else:
        print("\n".join(lines))
    return EXIT_OK


# --- CLI --------------------------------------------------------------------------------


def build_parser():
    p = argparse.ArgumentParser(prog="todo_queue.py", description=__doc__.splitlines()[0])
    p.add_argument("--todo-dir", default=str(Path.home() / ".claude" / "todo"))
    p.add_argument("--now", help="ISO8601Z timestamp override (tests)")
    p.add_argument("--today", help="YYYY-MM-DD override (tests)")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("init", help="idempotent migration + layout")

    v = sub.add_parser("validate", help="3-valued enum contract check")
    v.add_argument("--sweep")
    v.add_argument("--queue")
    v.add_argument("--run")

    f = sub.add_parser("filter", help="regenerate candidates.jsonl from a sweep")
    f.add_argument("--sweep", required=True)
    f.add_argument("--run", required=True)
    f.add_argument("--prev")
    f.add_argument("--config")
    f.add_argument("--out")
    f.add_argument("--run-log")

    s = sub.add_parser("summary", help="20-line state view")
    s.add_argument("--json", action="store_true")
    s.add_argument("--logs")
    return p


def main(argv=None):
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:  # argparse already printed usage
        return EXIT_USAGE if exc.code else EXIT_OK
    now = utc_now_iso(args.now)
    today = today_from(args.today, args.now)
    try:
        now_dt = dt.datetime.fromisoformat(now.replace("Z", "+00:00"))
    except ValueError:
        now_dt = dt.datetime.now(dt.timezone.utc)
    try:
        if args.cmd == "init":
            return cmd_init(args.todo_dir, now, today)
        if args.cmd == "validate":
            if not args.sweep and not args.queue:
                parser.error("validate needs --sweep and/or --queue")
            return cmd_validate(args)
        if args.cmd == "filter":
            return cmd_filter(args, args.todo_dir, now, today)
        if args.cmd == "summary":
            return cmd_summary(args, args.todo_dir, today, now_dt)
        parser.error(f"unknown subcommand {args.cmd}")
    except ValidationError as exc:
        for e in exc.errors:
            print(e, file=sys.stderr)
        return EXIT_VALIDATION
    except JsonError as exc:
        print(str(exc), file=sys.stderr)
        return EXIT_JSON
    except FileNotFoundError as exc:
        print(f"missing file: {exc}", file=sys.stderr)
        return EXIT_USAGE
    except SystemExit as exc:
        if isinstance(exc.code, str):
            print(exc.code, file=sys.stderr)
            return EXIT_USAGE
        return exc.code if isinstance(exc.code, int) else EXIT_USAGE
    except Exception as exc:  # noqa: BLE001 — last resort, keep the runner informed
        print(f"todo_queue.py: unexpected error: {exc.__class__.__name__}: {exc}", file=sys.stderr)
        return EXIT_ERROR
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
