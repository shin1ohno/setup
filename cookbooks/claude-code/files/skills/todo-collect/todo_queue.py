#!/usr/bin/env python3
"""todo_queue.py — queue helper for the /todo-collect pipeline (stdlib only).

Owns the machine-readable half of ~/.claude/todo: the O(open) approval queue
`candidates.jsonl` (one meta line, then one candidate per line), the write-once
`runs/` history layout, the 1-line-per-run `ledger.md` index header, and the
on-demand `summary` view. Design of record: docs/todo-management.md ("Queue",
"Dispositions", "Run logs and index", "Aging", "Approval surfaces").

Why Python and not a sibling of remind_sync.rb: the headless runner on the
always-on work box executes this from a systemd user unit whose PATH resolves
/usr/bin/python3 but no ruby (rbenv shims are an interactive-shell thing).
Everything here is stdlib, so /usr/bin/python3 3.x is enough.

Subcommands:
  init                    idempotent: runs/ + tmp/, legacy ledger -> runs/0000-legacy-*,
                          3-line index, meta-only candidates.jsonl
  validate --sweep P      3-valued enum contract of a sweep.json
  validate --queue P      same for a candidates.jsonl
  filter   --sweep P --run RUN_TS [--prev Q] [--config C] [--out Q] [--run-log L]
           [--applied A]  deterministic queue regeneration (dedup -> disposition ->
                          snooze -> aging -> ttl); prints the meta + per-key report.
                          With surfaces.queue_surface = slack-self-dm it also picks
                          the next candidates to announce (dm_per_run_max)
  summary  [--json]       20-line state view; never fails on a missing file
  set-announce --key K --channel C --ts T
                          record where a candidate's DM landed (call once per send)
  render-dm --key K       the DM body for one candidate
  ingest-reactions --reactions R --run RUN_TS [--records D] [--no-write]
                          turn the reactions read off the self-DM into actions
                          (approve / reject / snooze / never), needs_review marks
                          (conflict, stale) and revert candidates; the SIDE EFFECTS
                          (memory writes, thread replies) stay with the skill
  render-canvas [--exclude K,K] [--section N] [--json]
                          the 5-section standing view (状態 / 承認待ち / store 別 open /
                          待ち PR / 使い方) as Canvas-flavored Markdown; the skill
                          creates/rewrites the Slack Canvas from it
  set-canvas --id F --url U [--run RUN_TS] | --clear
                          record the canvas in surfaces.json (the runner checks last_run)
  set-store --name S --state complete|truncated|unreached [--open N] [--remaining R]
            [--reason X] [--air-pending N] [--run RUN_TS]
                          upsert one store's 3-valued open count in stores.json

Exit codes: 0 ok · 1 unexpected error · 2 usage / unreadable path · 3 validation
failure (one `<file>: <path>: <message>` line per violation on stderr) · 4 input
is not valid JSON.

The queue is a derived VIEW, not a store of truth: a candidate row is a raw
capture that has not been approved yet, and every disposition (approve, reject,
snooze, never, done, expired, revive) lives in the memory store as an
append-only record. This helper only reads those records (handed over in
sweep.json / --records) and never talks to the store itself.
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
ACTION_KINDS = ("approve", "reject", "snooze", "never")
CANON_PREFIXES = ("slack:", "notion:", "transcript:", "reminders:", "gtasks:")
DEFAULT_QUEUE_CONFIG = {"ttl_days": 21, "dm_per_run_max": 10, "snooze_days": 7}
DEFAULT_REACTIONS = {"approve": "white_check_mark", "reject": "x", "snooze": "zzz", "never": "mute"}
DEFAULT_SURFACES = {"queue_surface": "none", "channel": None, "reactions": dict(DEFAULT_REACTIONS)}
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
ANNOUNCE_RE = re.compile(r"(?m)^announce=([A-Za-z0-9]+)/(\d+\.\d+)")
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


def slack_ts_to_date(ts):
    """A Slack ts ("1788448581.084969") -> UTC date, or None."""
    try:
        return dt.datetime.fromtimestamp(float(ts), dt.timezone.utc).date()
    except (TypeError, ValueError, OverflowError):
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
    """Keys a todo record already claims: its `key=` lines, plus any Slack permalink in
    its body. Records written before the 2026-09 normalisation carry only the permalink
    (2026-09-04: such a todo, approved 08-17, was re-proposed as a candidate)."""
    keys = set()
    for rec in records or []:
        content = rec.get("content") if isinstance(rec, dict) else None
        if isinstance(content, str):
            keys.update(KEY_LINE_RE.findall(content))
            for m in SLACK_PERMALINK_RE.finditer(content):
                k = slack_key_from_permalink(m.group(0))
                k = k[0] if isinstance(k, tuple) else k
                if k:
                    keys.add(k)
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
        "applied_hidden": 0,
        "expired": 0,
        "announced": 0,
        "announce_pending": 0,
        "to_announce": [],
        "surface": "none",
        "filters_skipped": [],
        "dispositions_enum": dict(env),
        "todos_enum": dict(env),
        "sources": [],
        "ttl_days": DEFAULT_QUEUE_CONFIG["ttl_days"],
        "expired_keys": [],
        "origin_ts_missing": [],
    }


def load_config(path):
    base = {"queue": dict(DEFAULT_QUEUE_CONFIG), "sources": [], "surfaces": json.loads(json.dumps(DEFAULT_SURFACES))}
    if path is None:
        return base
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
    base["queue"].update(cfg.get("queue") or {})
    base["sources"] = cfg.get("sources") or []
    surfaces = cfg.get("surfaces") or {}
    reactions = dict(DEFAULT_REACTIONS)
    reactions.update(surfaces.get("reactions") or {})
    base["surfaces"].update({k: v for k, v in surfaces.items() if k != "reactions"})
    base["surfaces"]["reactions"] = reactions
    return base


def filter_queue(prev_rows, sweep, config, run, today, now, applied_keys=()):
    """Pure function. Returns (meta, rows, report)."""
    ttl_days = int(config["queue"].get("ttl_days", DEFAULT_QUEUE_CONFIG["ttl_days"]))
    dm_max = int(config["queue"].get("dm_per_run_max", DEFAULT_QUEUE_CONFIG["dm_per_run_max"]))
    surface = (config.get("surfaces") or {}).get("queue_surface") or "none"
    sources_cfg = {s.get("name"): s for s in config.get("sources", []) if isinstance(s, dict)}
    prev_by_key = {r.get("key"): r for r in prev_rows if isinstance(r, dict) and r.get("type") == "candidate"}
    applied = set(applied_keys or ())

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
    counts = {"deduped": 0, "rejected_hidden": 0, "snoozed_hidden": 0, "applied_hidden": 0, "aged_out": 0, "expired": 0}

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

        # Disposed earlier in THIS run (a reaction or /todo-approve decision applied a
        # minute ago): the store already has the record but the dispositions snapshot
        # in sweep.json predates it, so the caller passes the keys explicitly.
        if key in applied:
            counts["applied_hidden"] += 1
            report["hidden"].append({"key": key, "kind": "applied", "written_at": now})
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
                "announce_pending": False,
                "review_reason": prev.get("review_reason") if state == "needs_review" else None,
                "snooze_wake": snooze_wake,
                "state": state,
            }
        )

    rows.sort(key=lambda r: ((r.get("origin_ts") or ""), r["key"]))

    # Which candidates get a self-DM this run. Only open rows without an announce,
    # oldest origin first, capped — the cap is what keeps a bulk-saved day from
    # turning the self-DM into spam; the remainder is marked and goes out tomorrow.
    to_announce = []
    if surface == "slack-self-dm":
        waiting = [r for r in rows if r["state"] == "open" and not r.get("announce")]
        for i, r in enumerate(waiting):
            if i < dm_max:
                to_announce.append(r["key"])
            else:
                r["announce_pending"] = True

    meta = empty_meta(run, now, today, reason="")
    meta.update(
        {
            "open": sum(1 for r in rows if r["state"] == "open"),
            "needs_review": sum(1 for r in rows if r["state"] == "needs_review"),
            "aged_out": counts["aged_out"],
            "deduped": counts["deduped"],
            "rejected_hidden": counts["rejected_hidden"],
            "snoozed_hidden": counts["snoozed_hidden"],
            "applied_hidden": counts["applied_hidden"],
            "expired": counts["expired"],
            "announced": sum(1 for r in rows if r.get("announce")),
            "announce_pending": sum(1 for r in rows if r.get("announce_pending")),
            "to_announce": to_announce,
            "surface": surface,
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


# --- approval surface: DM rendering + reaction ingest ---------------------------------


def render_dm(row, today, snooze_days=DEFAULT_QUEUE_CONFIG["snooze_days"]):
    """The self-DM body for one candidate. Line 1 carries the canonical key and the
    `[todo-loop]` prefix that keeps the self-DM sweep from re-capturing it."""
    origin = parse_date(row.get("origin_ts"))
    age = f"{(today - origin).days} 日前" if origin else "日付不明"
    due = row.get("due") or "なし"
    draft = row.get("draft_close_condition") or "（未起草 — 承認時に補う）"
    lines = [
        f"[todo-loop] 候補 key={row['key']}",
        f"*{row.get('title') or '(無題)'}*（{row.get('source')}、{origin.isoformat() if origin else '?'} = {age}、期日 {due}）",
        f"完了条件案: {draft}",
    ]
    if row.get("permalink"):
        # A bare URL line directly followed by another line makes the Slack connector's
        # slack_send_message fail with invalid_blocks (measured 2026-09-04, ASCII-only
        # bodies included); a blank line after the URL is what makes it accept the body.
        lines.append(f"元: {row['permalink']}")
        lines.append("")
    lines.append(
        f"✅ 承認 / ❌ 却下 / 💤 {snooze_days} 日保留 / 🔇 このスレッドは今後除外（反映は翌 07:23 JST の collect）"
    )
    return "\n".join(lines)


def _reaction_kinds(message, name_to_kind):
    kinds = set()
    for r in message.get("reactions") or []:
        name = (r.get("name") or "").strip(":")
        if name in name_to_kind and int(r.get("count") or 0) > 0:
            kinds.add(name_to_kind[name])
    return kinds


def _record_announces(records):
    """[(channel, ts, record)] for every record whose content carries an announce= line."""
    out = []
    for rec in records or []:
        content = rec.get("content") if isinstance(rec, dict) else None
        if not isinstance(content, str):
            continue
        for m in ANNOUNCE_RE.finditer(content):
            out.append((m.group(1), m.group(2), rec))
    return out


def ingest_reactions(rows, messages, config, today, now, records=None):
    """Pure function. rows: queue candidate rows; messages: [{ts, channel?, reactions:[{name,count}]}]
    read off the self-DM; records: memory records (todos + dispositions) whose content may
    carry `announce=<channel>/<ts>` for reversal detection.

    Returns (actions, needs_review, revert_candidates, announce_missing, rows) where rows
    is the input list with needs_review / review_reason updated in place."""
    reactions_cfg = (config.get("surfaces") or {}).get("reactions") or DEFAULT_REACTIONS
    name_to_kind = {str(v).strip(":"): k for k, v in reactions_cfg.items() if k in ACTION_KINDS}
    ttl_days = int(config["queue"].get("ttl_days", DEFAULT_QUEUE_CONFIG["ttl_days"]))
    snooze_days = int(config["queue"].get("snooze_days", DEFAULT_QUEUE_CONFIG["snooze_days"]))
    by_ts = {str(m.get("ts")): m for m in messages or [] if m.get("ts")}

    actions, needs_review, announce_missing = [], [], []
    for row in rows:
        ann = row.get("announce") or {}
        ts = str(ann.get("ts") or "")
        if not ts:
            continue
        msg = by_ts.get(ts)
        if msg is None:
            announce_missing.append({"key": row["key"], "announce": ann})
            continue
        kinds = _reaction_kinds(msg, name_to_kind)
        if not kinds:
            continue
        announced_on = parse_date(ann.get("at")) or slack_ts_to_date(ts) or parse_date(row.get("first_seen")) or today
        if (today - announced_on).days > ttl_days:
            row["state"] = "needs_review"
            row["review_reason"] = f"stale reaction: DM announced {announced_on.isoformat()}, over {ttl_days} days ago"
            needs_review.append({"key": row["key"], "reason": row["review_reason"], "kinds": sorted(kinds)})
            continue
        if len(kinds) > 1:
            row["state"] = "needs_review"
            row["review_reason"] = f"conflicting reactions: {', '.join(sorted(kinds))}"
            needs_review.append({"key": row["key"], "reason": row["review_reason"], "kinds": sorted(kinds)})
            continue
        kind = next(iter(kinds))
        action = {
            "key": row["key"],
            "kind": kind,
            "source": row.get("source"),
            "thread_key": row.get("thread_key"),
            "title": row.get("title"),
            "permalink": row.get("permalink"),
            "draft_close_condition": row.get("draft_close_condition"),
            "announce": f"{ann.get('channel')}/{ts}",
        }
        if kind == "snooze":
            action["until"] = (today + dt.timedelta(days=snooze_days)).isoformat()
        actions.append(action)

    # Reversal: a record already written for a candidate (the approved todo, or a
    # reject / snooze / never disposition) whose DM now carries a reaction that
    # contradicts it. The skill decides what to do (forget + done, revive, or just
    # ask) — provenance decides whether the box may touch the record at all.
    revert_candidates = []
    for channel, ts, rec in _record_announces(records):
        msg = by_ts.get(ts)
        if msg is None:
            continue
        kinds = _reaction_kinds(msg, name_to_kind)
        if not kinds:
            continue
        d = parse_disposition(rec)
        current = d["kind"] if d else "approve"
        contradicting = sorted(k for k in kinds if k != current)
        if not contradicting:
            continue
        keys = KEY_LINE_RE.findall(rec.get("content", "")) or ([d["key"]] if d else [])
        revert_candidates.append(
            {
                "key": keys[0] if keys else None,
                "id": rec.get("id"),
                "current": current,
                "reactions": contradicting,
                "announce": f"{channel}/{ts}",
                "source_class": ((rec.get("provenance") or {}).get("source_class")),
            }
        )
    return actions, needs_review, revert_candidates, announce_missing, rows


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


def refresh_meta_counts(meta, rows):
    meta["open"] = sum(1 for r in rows if r.get("state") == "open")
    meta["needs_review"] = sum(1 for r in rows if r.get("state") == "needs_review")
    meta["announced"] = sum(1 for r in rows if r.get("announce"))
    meta["announce_pending"] = sum(1 for r in rows if r.get("announce_pending"))
    return meta


def append_run_log(path, run, meta, report):
    lines = [f"### queue filter ({run})", ""]
    lines.append(
        f"- open {meta['open']} / needs_review {meta['needs_review']} / aged_out {meta['aged_out']} / "
        f"deduped {meta['deduped']} / hidden {meta['rejected_hidden'] + meta['snoozed_hidden'] + meta.get('applied_hidden', 0)} / expired {meta['expired']}"
    )
    if meta.get("surface") == "slack-self-dm":
        lines.append(f"- to announce this run: {len(meta.get('to_announce') or [])} / pending beyond cap: {meta.get('announce_pending', 0)}")
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


def _config_for(args, todo_dir, run=None):
    config_path = getattr(args, "config", None)
    if config_path is None and run:
        candidate = Path(todo_dir) / "tmp" / f"{run}-config.json"
        config_path = str(candidate) if candidate.exists() else None
    return load_config(config_path)


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
    applied_keys = []
    if args.applied:
        doc = load_json(args.applied)
        applied_keys = doc.get("keys", []) if isinstance(doc, dict) else list(doc)
    config = _config_for(args, todo_dir, args.run)
    meta, rows, report = filter_queue(prev_rows, sweep, config, args.run, today, now, applied_keys=applied_keys)
    out = Path(args.out) if args.out else todo_dir / "candidates.jsonl"
    write_queue(out, meta, rows)
    if args.run_log:
        append_run_log(args.run_log, args.run, meta, report)
    result = dict(meta)
    result.update(report)
    result["out"] = str(out)
    print(dumps(result))
    return EXIT_OK


def cmd_set_announce(args, todo_dir, now):
    queue = Path(args.queue) if args.queue else Path(todo_dir) / "candidates.jsonl"
    meta, rows = read_queue(queue)
    if meta is None:
        raise ValidationError([f"{queue}: missing or without a meta line"])
    hit = None
    for r in rows:
        if r.get("key") == args.key:
            hit = r
            break
    if hit is None:
        raise ValidationError([f"{queue}: key {args.key} is not in the queue"])
    hit["announce"] = {"channel": args.channel, "ts": str(args.ts), "at": now}
    hit["announce_pending"] = False
    refresh_meta_counts(meta, rows)
    meta["to_announce"] = [k for k in (meta.get("to_announce") or []) if k != args.key]
    write_queue(queue, meta, rows)
    print(dumps({"key": args.key, "announce": hit["announce"], "announced": meta["announced"]}))
    return EXIT_OK


def cmd_render_dm(args, todo_dir, today):
    queue = Path(args.queue) if args.queue else Path(todo_dir) / "candidates.jsonl"
    _, rows = read_queue(queue)
    for r in rows:
        if r.get("key") == args.key:
            config = _config_for(args, todo_dir)
            print(render_dm(r, today, int(config["queue"].get("snooze_days", DEFAULT_QUEUE_CONFIG["snooze_days"]))))
            return EXIT_OK
    raise ValidationError([f"{queue}: key {args.key} is not in the queue"])


def cmd_ingest_reactions(args, todo_dir, now, today):
    queue = Path(args.queue) if args.queue else Path(todo_dir) / "candidates.jsonl"
    meta, rows = read_queue(queue)
    if meta is None:
        raise ValidationError([f"{queue}: missing or without a meta line"])
    doc = load_json(args.reactions)
    messages = doc.get("messages", []) if isinstance(doc, dict) else list(doc)
    records = []
    if args.records:
        rdoc = load_json(args.records)
        records = rdoc.get("records", []) if isinstance(rdoc, dict) else list(rdoc)
    config = _config_for(args, todo_dir, args.run)
    actions, needs_review, reverts, missing, rows = ingest_reactions(rows, messages, config, today, now, records)
    if not args.no_write:
        refresh_meta_counts(meta, rows)
        write_queue(queue, meta, rows)
    print(
        dumps(
            {
                "run": args.run,
                "actions": actions,
                "needs_review": needs_review,
                "revert_candidates": reverts,
                "announce_missing": missing,
                "messages_read": len(messages),
                "applied_keys": [a["key"] for a in actions],
            }
        )
    )
    return EXIT_OK


def _age_days(iso, today):
    d = parse_date(iso)
    return (today - d).days if d else None


def _read_text(path):
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None


def build_summary(todo_dir, logs_dir, today, now_dt, stores_path=None, prs_path=None):
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
            "hidden": (meta.get("rejected_hidden") or 0) + (meta.get("snoozed_hidden") or 0) + (meta.get("applied_hidden") or 0),
            "expired": meta.get("expired"),
            "announced": meta.get("announced"),
            "announce_pending": meta.get("announce_pending"),
            "surface": meta.get("surface"),
            "generated_at": meta.get("generated_at"),
        }
        lines.append(
            f"queue: open {meta.get('open')} (needs_review {meta.get('needs_review')}) oldest {oldest}d "
            f"run {meta.get('run')} aged_out {meta.get('aged_out')} hidden {out['queue']['hidden']} expired {meta.get('expired')}"
        )
        if meta.get("surface") and meta.get("surface") != "none":
            lines.append(
                f"surface {meta.get('surface')}: announced {meta.get('announced', 0)} / pending {meta.get('announce_pending', 0)}"
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

    stores_text = _read_text(Path(stores_path) if stores_path else todo_dir / "stores.json")
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

    prs_text = _read_text(Path(prs_path) if prs_path else todo_dir / "prs.json")
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


# --- canvas / stores / surfaces ---------------------------------------------------------
#
# The standing view is a Slack Canvas the collect run rewrites wholesale (heading and
# body are separate canvas sections, so a targeted "replace section 2" is fragile; a
# full replace in one atomic update is not). Everything below is pure rendering over
# the files this helper already owns plus stores.json / prs.json; the Slack calls stay
# with the skill.

CANVAS_TITLE = "TODO queue"
CANVAS_HEADINGS = ("1. 状態", "2. 承認待ち", "3. store 別 open", "4. 待ち PR", "5. 使い方")
STALE_HOURS = 30
JST = dt.timezone(dt.timedelta(hours=9), name="JST")
SLACK_HOST_RE = re.compile(r"https?://([^/\s]+)/archives/")


def surfaces_path(todo_dir):
    return Path(todo_dir) / "surfaces.json"


def load_surfaces(todo_dir):
    """surfaces.json — where the standing Canvas lives. Absent is a normal state."""
    path = surfaces_path(todo_dir)
    text = _read_text(path)
    if not text:
        return {"schema": SCHEMA_VERSION, "canvas": None}
    try:
        doc = json.loads(text)
    except json.JSONDecodeError as exc:
        raise JsonError(f"{path}: invalid JSON: {exc}") from None
    if not isinstance(doc, dict):
        raise JsonError(f"{path}: expected a JSON object")
    doc.setdefault("schema", SCHEMA_VERSION)
    doc.setdefault("canvas", None)
    return doc


def slack_message_url(host, channel, ts):
    sec, _, frac = str(ts).partition(".")
    return f"https://{host}/archives/{channel}/p{sec}{frac.ljust(6, '0')[:6]}"


def slack_host_for(rows, config):
    """Workspace host for DM links: config surfaces.slack_host, else the host of any
    candidate permalink (the workspace the loop reads from), else bare slack.com."""
    host = (config.get("surfaces") or {}).get("slack_host")
    if host:
        return str(host)
    for r in rows:
        m = SLACK_HOST_RE.match(str(r.get("permalink") or ""))
        if m:
            return m.group(1)
    return "slack.com"


def _jst(iso):
    if not iso:
        return "—"
    try:
        d = dt.datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
    except ValueError:
        return str(iso)
    if d.tzinfo is None:
        d = d.replace(tzinfo=dt.timezone.utc)
    return d.astimezone(JST).strftime("%Y-%m-%d %H:%M JST")


def _cell(text, limit=70):
    """One table cell: single line, no pipe, bounded length."""
    s = " ".join(str(text if text is not None else "").split()).replace("|", "／")
    return s if len(s) <= limit else s[: limit - 1] + "…"


def _table(headers, rows):
    out = ["| " + " | ".join(headers) + " |", "|" + "---|" * len(headers)]
    out += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return out


def _section(n, body_lines, heading_extra=""):
    heading = f"{CANVAS_HEADINGS[n - 1]}{heading_extra}"
    return {"n": n, "heading": heading, "markdown": f"# {heading}\n" + "\n".join(body_lines) + "\n"}


def canvas_markdown(sections):
    return "\n".join(s["markdown"] for s in sections)


def live_rows(rows, exclude=()):
    excluded = set(exclude or ())
    return [r for r in rows if r.get("key") not in excluded and r.get("state") in ("open", "needs_review")]


def _hours_since(iso, now_dt):
    if not iso or now_dt is None:
        return None
    try:
        d = dt.datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=dt.timezone.utc)
    return round((now_dt - d).total_seconds() / 3600, 1)


def render_canvas(meta, rows, summary, config, today, exclude=(), now_dt=None):
    """The 5-section standing view as Canvas-flavored Markdown (ATX `#` headings only,
    tables, bullet lists with inline formatting). `summary` is build_summary()'s dict
    (stores / prs / loops / stale); `exclude` hides keys disposed in the current
    interactive session without touching the queue file. Returns [{n, heading, markdown}]."""
    meta = meta or {}
    q = config.get("queue") or {}
    sf = config.get("surfaces") or {}
    reactions = dict(DEFAULT_REACTIONS)
    reactions.update({k: v for k, v in (sf.get("reactions") or {}).items() if v})
    live = live_rows(rows, exclude)
    host = slack_host_for(rows, config)
    sections = []

    # 1. 状態 — the age is measured from the queue's own generated_at, not from the
    # runner's .last: the canvas is rendered MID-run, when .last still points at the
    # previous ok run (first live canvas, 2026-09-04: "21:52 JST … 14.4h 前"). The stale
    # flag from .last is likewise overridden by a queue regenerated within STALE_HOURS —
    # the run that wrote it is evidently alive.
    lines = []
    collect = (summary.get("loops") or {}).get("todo-collect") or {}
    gen_hours = _hours_since(meta.get("generated_at"), now_dt)
    hours = gen_hours if gen_hours is not None else collect.get("hours_ago")
    if meta:
        ago = f"、{hours}h 前" if hours is not None else ""
        lines.append(f"- 最終 collect run: {_jst(meta.get('generated_at'))}（run `{meta.get('run')}`{ago}）")
    else:
        lines.append("- 最終 collect run: データなし（`candidates.jsonl` 不在 — `todo_queue.py init` 未実行）")
    if sf.get("schedule_label"):
        lines.append(f"- 次回: {sf['schedule_label']}")
    stale = "todo-collect" in (summary.get("stale") or []) and (gen_hours is None or gen_hours > STALE_HOURS)
    if stale:
        lines.append(
            f"- :red_circle: **停止中** — 最終 run から {hours}h（{STALE_HOURS}h 超）。"
            "`~/.claude/logs/todo-collect.log` と `~/.claude/todo-collect.DISABLED` を確認"
        )
    else:
        lines.append(f"- 最終更新から {STALE_HOURS} 時間超 = 停止中（超えるとこの行が赤丸の警告に変わる）")
    unswept = [s for s in (meta.get("sources") or []) if s.get("status") in ("unswept", "truncated")]
    if unswept:
        parts = []
        for s in unswept:
            if s.get("status") == "truncated":
                parts.append(f"{s.get('name')}（truncated 残 {s.get('remaining')}）")
            else:
                parts.append(f"{s.get('name')}（{s.get('reason') or '理由未記載'}）")
        lines.append("- 未 sweep: " + " / ".join(parts))
    else:
        lines.append("- 未 sweep: なし")
    if meta:
        de = meta.get("dispositions_enum") or {}
        te = meta.get("todos_enum") or {}
        dn = de.get("total") if de.get("total") is not None else "-"
        tn = te.get("total") if te.get("total") is not None else "-"
        lines.append(f"- 列挙: dispositions {de.get('state')} {dn} 件 / todos {te.get('state')} {tn} 件")
        if meta.get("filters_skipped"):
            lines.append(
                f"- :warning: disposition フィルタ未適用（{', '.join(meta['filters_skipped'])}）— 却下済みが再表示されている可能性"
            )
    sections.append(_section(1, lines))

    # 2. 承認待ち
    nr = sum(1 for r in live if r.get("state") == "needs_review")
    extra = f"（{len(live)} 件" + (f"、要確認 {nr} 件" if nr else "") + "）"
    lines = []
    if not live:
        lines.append("承認待ちはありません。")
    else:
        trows = []
        for i, r in enumerate(live, 1):
            title = _cell(r.get("title") or r.get("key"))
            if r.get("state") == "needs_review":
                title = f":warning: {title}（要確認）"
            age = _age_days(r.get("origin_ts"), today)
            if age is None:
                age = _age_days(r.get("first_seen"), today)
            ann = r.get("announce") or {}
            if ann.get("ts"):
                dm = f"[DM]({slack_message_url(host, ann.get('channel') or sf.get('channel') or '', ann['ts'])})"
            elif r.get("announce_pending"):
                dm = "未送信（翌 run）"
            else:
                dm = "—"
            src = f"[元]({r['permalink']})" if r.get("permalink") else f"`{_cell(r.get('key'), 40)}`"
            trows.append((i, title, _cell(r.get("source"), 30), _cell(r.get("due") or "—", 12), age if age is not None else "—", dm, src))
        lines += _table(("#", "候補", "源", "期日", "経過日", "DM", "元"), trows)
    if exclude:
        lines.append("")
        lines.append(f"処置済み {len(set(exclude))} 件を除いた表です（queue 本体は翌 collect run で更新）。")
    sections.append(_section(2, lines, extra))

    # 3. store 別 open — one row per store, exactly one of the four 3-valued columns filled
    lines = []
    stores = summary.get("stores")
    if not stores:
        lines.append("データなし（`stores.json` 未作成 — reconcile と collect の `set-store` が書く）")
    else:
        trows = []
        for name, st in (stores.get("stores") or {}).items():
            if not isinstance(st, dict):
                continue
            cols = ["", "", "", ""]
            state = st.get("state")
            if state == "complete":
                n = st.get("open")
                if n in (0, "0"):
                    cols[1] = "0"
                else:
                    cols[0] = str(n if n is not None else "-")
            elif state == "unreached":
                cols[2] = _cell(st.get("reason") or "理由未記載", 40)
            elif state == "truncated":
                cols[3] = str(st.get("remaining") if st.get("remaining") is not None else "unknown")
            else:
                cols[2] = f"state 不明（{state}）"
            trows.append((_cell(name, 30), *cols))
        lines += _table(("store", "列挙完了 N", "0 件", "未列挙（理由）", "truncated 残数"), trows) if trows else ["（store 行なし）"]
        lines.append("")
        apf = stores.get("air_pending_forget")
        lines.append(
            f"air 待ち forget: {apf if apf is not None else '—'} 件"
            "（user-stated の todo は箱から forget できない。laptop で `/todo-approve --apply-air-pending`）"
        )
        lines.append(f"as of {_jst(stores.get('written_at'))}（run `{stores.get('run')}`）")
    sections.append(_section(3, lines))

    # 4. 待ち PR
    lines = []
    prs = summary.get("prs")
    flag = sf.get("pr_merge_flag", "--merge")
    if not prs:
        lines.append("データなし（`prs.json` 未作成 — reconcile runner が書く）")
    elif prs.get("prs") is None:
        lines.append(f":warning: 取得失敗（{prs.get('error') or 'error unknown'}）— as of {_jst(prs.get('written_at'))}")
    elif not prs["prs"]:
        lines.append(f"待ち PR なし — as of {_jst(prs.get('written_at'))}")
    else:
        trows = []
        for pr in prs["prs"]:
            repo, num = pr.get("repo"), pr.get("number")
            label = f"{repo}#{num}"
            link = f"[{label}]({pr['url']})" if pr.get("url") else label
            age = _age_days(pr.get("createdAt"), today)
            trows.append(
                (link, pr.get("mergeStateStatus") or "-", age if age is not None else "—", f"`gh -R {repo} pr merge {num} {flag} --delete-branch`")
            )
        lines += _table(("PR", "mergeStateStatus", "経過日", "実行"), trows)
        lines.append("")
        lines.append(f"as of {_jst(prs.get('written_at'))}")
    sections.append(_section(4, lines))

    # 5. 使い方
    snooze = q.get("snooze_days", DEFAULT_QUEUE_CONFIG["snooze_days"])
    lines = [
        f"- 候補 DM へのリアクション 1 回で処置: :{reactions['approve']}: 承認 / :{reactions['reject']}: 却下 / "
        f":{reactions['snooze']}: {snooze} 日 snooze / :{reactions['never']}: このスレッドを今後除外。"
        f"反映は翌 collect run（{sf.get('schedule_label') or '毎日'}）。",
        "- 対話で処置: `/todo-approve`（4 件ずつ）。`--list` 状態表示 / `--revive <key>` 却下の取消 / "
        "`--undo <key>` 承認の取消 / `--apply-air-pending` は laptop で air 待ち forget を一括処置。",
        "- この Canvas は collect run ごとに全文置換されます（手編集は次回消えます）。"
        "生成元: `todo_queue.py render-canvas`、真実源: memory store の todo / todo-disposition レコード。",
    ]
    sections.append(_section(5, lines))
    return sections


def cmd_render_canvas(args, todo_dir, today, now_dt):
    todo_dir = Path(todo_dir)
    queue = Path(args.queue) if args.queue else todo_dir / "candidates.jsonl"
    try:
        meta, rows = read_queue(queue)
    except FileNotFoundError:
        meta, rows = None, []
    logs_dir = args.logs or str(todo_dir.parent / "logs")
    summary, _ = build_summary(todo_dir, logs_dir, today, now_dt, stores_path=args.stores, prs_path=args.prs)
    config = _config_for(args, todo_dir)
    surfaces = load_surfaces(todo_dir)
    exclude = [k for k in (args.exclude or "").split(",") if k]
    sections = render_canvas(meta, rows, summary, config, today, exclude=exclude, now_dt=now_dt)
    if args.section:
        sections = [s for s in sections if s["n"] == args.section]
    if args.json:
        live = live_rows(rows, exclude)
        print(
            dumps(
                {
                    "title": (surfaces.get("canvas") or {}).get("title") or CANVAS_TITLE,
                    "canvas": surfaces.get("canvas"),
                    "sections": sections,
                    "markdown": canvas_markdown(sections),
                    "open": sum(1 for r in live if r.get("state") == "open"),
                    "needs_review": sum(1 for r in live if r.get("state") == "needs_review"),
                    "excluded": len(set(exclude)),
                }
            )
        )
    else:
        sys.stdout.write(canvas_markdown(sections))
    return EXIT_OK


def cmd_set_canvas(args, todo_dir, now):
    doc = load_surfaces(todo_dir)
    prev = doc.get("canvas") or {}
    if args.clear:
        doc["canvas"] = None
    else:
        if not args.id or not args.url:
            raise ValidationError(["set-canvas needs --id and --url (or --clear)"])
        same = prev.get("id") == args.id
        doc["canvas"] = {
            "id": args.id,
            "url": args.url,
            "title": args.title or prev.get("title") or CANVAS_TITLE,
            "created_at": prev.get("created_at") if same and prev.get("created_at") else now,
            "updated_at": now,
            "last_run": args.run or (prev.get("last_run") if same else None),
            "updates": (prev.get("updates") or 0) + 1 if same else 1,
        }
    doc["written_at"] = now
    write_atomic(surfaces_path(todo_dir), dumps(doc) + "\n")
    print(dumps(doc))
    return EXIT_OK


def cmd_set_store(args, todo_dir, now):
    """Upsert one store's 3-valued open count in stores.json (reconcile weekly, collect
    daily for the store it enumerated). Other stores' entries are preserved."""
    path = Path(args.stores) if args.stores else Path(todo_dir) / "stores.json"
    doc = {"written_at": now, "run": None, "stores": {}, "air_pending_forget": None}
    text = _read_text(path)
    if text:
        try:
            loaded = json.loads(text)
        except json.JSONDecodeError as exc:
            raise JsonError(f"{path}: invalid JSON: {exc}") from None
        if isinstance(loaded, dict):
            doc.update(loaded)
    if not isinstance(doc.get("stores"), dict):
        doc["stores"] = {}
    if not args.name and args.air_pending is None:
        raise ValidationError(["set-store needs --name (with --state) and/or --air-pending"])
    if args.name:
        errors = []
        if args.state not in ENUM_STATES:
            errors.append(f"--state must be one of {'|'.join(ENUM_STATES)}, got {args.state!r}")
        if args.state == "complete" and args.open is None:
            errors.append("--state complete needs --open N")
        if args.state == "truncated" and args.remaining is None:
            errors.append("--state truncated needs --remaining N|unknown")
        if args.state == "unreached" and not args.reason:
            errors.append("--state unreached needs --reason")
        if errors:
            raise ValidationError([f"set-store: {e}" for e in errors])
        remaining = args.remaining
        if remaining is not None and remaining != "unknown":
            try:
                remaining = int(remaining)
            except ValueError:
                raise ValidationError(["set-store: --remaining must be an int or 'unknown'"]) from None
        doc["stores"][args.name] = {
            "state": args.state,
            "open": args.open,
            "remaining": remaining,
            "reason": args.reason or "",
            "written_at": now,
        }
    if args.air_pending is not None:
        doc["air_pending_forget"] = args.air_pending
    if args.run:
        doc["run"] = args.run
    doc["written_at"] = now
    write_atomic(path, json.dumps(doc, ensure_ascii=False, indent=2) + "\n")
    print(dumps(doc))
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
    f.add_argument("--applied", help="JSON {keys:[...]} disposed earlier in this run (hidden without waiting for the store)")

    s = sub.add_parser("summary", help="20-line state view")
    s.add_argument("--json", action="store_true")
    s.add_argument("--logs")

    a = sub.add_parser("set-announce", help="record the self-DM a candidate was announced in")
    a.add_argument("--key", required=True)
    a.add_argument("--channel", required=True)
    a.add_argument("--ts", required=True)
    a.add_argument("--queue")

    d = sub.add_parser("render-dm", help="print the self-DM body for one candidate")
    d.add_argument("--key", required=True)
    d.add_argument("--queue")
    d.add_argument("--config")

    i = sub.add_parser("ingest-reactions", help="turn self-DM reactions into actions / needs_review / reverts")
    i.add_argument("--reactions", required=True, help="JSON {messages:[{ts, channel, reactions:[{name,count}]}]}")
    i.add_argument("--run", required=True)
    i.add_argument("--queue")
    i.add_argument("--config")
    i.add_argument("--records", help="JSON {records:[...]} — todos + dispositions with announce= lines, for reversal detection")
    i.add_argument("--no-write", action="store_true", help="do not persist needs_review marks into the queue")

    c = sub.add_parser("render-canvas", help="Canvas-flavored Markdown of the 5-section standing view")
    c.add_argument("--queue")
    c.add_argument("--stores")
    c.add_argument("--prs")
    c.add_argument("--logs")
    c.add_argument("--config")
    c.add_argument("--exclude", help="comma-separated keys disposed in this session (hidden without touching the queue)")
    c.add_argument("--section", type=int, choices=range(1, len(CANVAS_HEADINGS) + 1), help="print one section only")
    c.add_argument("--json", action="store_true", help="{title, canvas, sections[], markdown, open, needs_review}")

    sc = sub.add_parser("set-canvas", help="record the standing canvas (surfaces.json) after create/update")
    sc.add_argument("--id")
    sc.add_argument("--url")
    sc.add_argument("--title")
    sc.add_argument("--run", help="run id that rewrote the canvas (the headless runner checks it)")
    sc.add_argument("--clear", action="store_true", help="forget the canvas (deleted in Slack; the next run recreates it)")

    st = sub.add_parser("set-store", help="upsert one store's 3-valued open count in stores.json")
    st.add_argument("--name")
    st.add_argument("--state", choices=ENUM_STATES)
    st.add_argument("--open", type=int)
    st.add_argument("--remaining", help="int or 'unknown' (truncated)")
    st.add_argument("--reason", help="why (unreached)")
    st.add_argument("--air-pending", type=int, help="air_pending_forget count (top-level)")
    st.add_argument("--run")
    st.add_argument("--stores", help="path override (default <todo-dir>/stores.json)")
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
        if args.cmd == "set-announce":
            return cmd_set_announce(args, args.todo_dir, now)
        if args.cmd == "render-dm":
            return cmd_render_dm(args, args.todo_dir, today)
        if args.cmd == "ingest-reactions":
            return cmd_ingest_reactions(args, args.todo_dir, now, today)
        if args.cmd == "render-canvas":
            return cmd_render_canvas(args, args.todo_dir, today, now_dt)
        if args.cmd == "set-canvas":
            return cmd_set_canvas(args, args.todo_dir, now)
        if args.cmd == "set-store":
            return cmd_set_store(args, args.todo_dir, now)
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
