"""Secret masking for Claude Code session transcripts (design spec §6.2, C2).

Single source of truth for BOTH sides of the session-search pipeline:

- the client (`ccs ingest`) masks every record before any byte leaves the host;
- the server (sessions_app) re-scans every received line in detect-only mode and
  rejects anything the declared ruleset still finds (422).

The client cookbook copies this file byte-for-byte into the `ccs` package, and
bin/check-memory-v2-manifest fails CI when the two copies differ. Keep it
stdlib-only and free of any import from this directory.

Frozen API (shared contract):

    RULESET_VERSION = "r1"
    load_key(path) -> bytes                     raises KeyMissing
    redact_record(record, key, version) -> (masked deep copy, {kind: count})
    redact_text(text, key, version) -> (masked text, {kind: count})
    detect_record(record, version) -> [kind, ...]   unmasked hits only

Two properties are load-bearing and covered by test_session_redact.py:

1. Fixed point: redact(redact(x)) == redact(x). Every rule runs only on the
   text OUTSIDE existing `[REDACTED:...]` placeholders, so a placeholder can
   never be matched again (without this, `bearer`'s `\\S{16,}` matches a
   24-character placeholder and the server re-scan rejects already-masked input).
2. Iterative walk: records are traversed with an explicit stack, so a
   10,000-deep structure cannot raise RecursionError.

Values are never logged or returned by the detector — only kind names.
"""

from __future__ import annotations

import hashlib
import hmac
import os
import re

RULESET_VERSION: str = "r1"
SUPPORTED_VERSIONS = frozenset({"r1"})


class KeyMissing(Exception):
    """The HMAC key file is absent, unreadable or empty. Callers fail closed:
    nothing is shipped and no cursor moves."""


def load_key(path: str) -> bytes:
    """Read the per-boundary HMAC key. Surrounding whitespace (a trailing
    newline from `echo` or SSM) is not part of the key."""
    try:
        with open(os.path.expanduser(path), "rb") as fh:
            key = fh.read().strip()
    except OSError as exc:
        raise KeyMissing(f"hmac key unreadable: {exc.__class__.__name__}") from None
    if not key:
        raise KeyMissing("hmac key is empty")
    return key


# --------------------------------------------------------------------------- #
# Ruleset r1
# --------------------------------------------------------------------------- #
# A placeholder this module (or an older client of it) produced. Text inside one
# is never scanned again.
PLACEHOLDER_RE = re.compile(r"\[REDACTED:[a-z0-9-]+(?::[0-9a-f]{8})?\]")

# Kinds whose matched value is high-entropy: tagged with an 8-hex HMAC so that a
# leaked token can be traced across sessions. Order matters: anthropic-key must
# run before openai-key (both start with `sk-`).
_TAGGED = (
    ("aws-key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("github-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}\b|\bgithub_pat_[A-Za-z0-9_]{60,}\b")),
    ("anthropic-key", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}")),
    ("openai-key", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}")),
    ("slack-token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}")),
    ("google-api-key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
    ("gitlab-token", re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}")),
)

# A truncated block (BEGIN without END, e.g. a capped tool_result) is masked to
# the end of the string: half a private key is still a private key.
_PRIVATE_KEY_RE = re.compile(
    r"-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----"
    r"(?:[\s\S]*?-----END [A-Z ]*PRIVATE KEY(?: BLOCK)?-----|[\s\S]*\Z)")

# Only the value is replaced; the header name stays readable. Also accepts the
# JSON / dict spelling `"Authorization": "Bearer ..."`.
_BEARER_RE = re.compile(
    r"(?i)(\bauthorization[\"']?\s*[:=]\s*[\"']?bearer\s+)([^\s\"']{16,})")

_URL_CRED_RE = re.compile(r"(?i)([a-z][a-z0-9+.-]*://[^\s/:@]+:)([^\s/@]+)(@)")

_CFG_KEY = r"[A-Za-z0-9_.-]*(?:secret|token|passw(?:or)?d|api[_-]?key|credential|private)[A-Za-z0-9_.-]*"
_CFG_KEY_RE = re.compile(r"(?i)" + _CFG_KEY)
# "KEY": "VALUE" (value may contain spaces and escaped quotes)
_CFG_JSON_RE = re.compile(r'(?i)("' + _CFG_KEY + r'"\s*:\s*")((?:[^"\\]|\\.)*)(")')
# KEY=VALUE / KEY: VALUE, optionally quoted key and value
_CFG_KV_RE = re.compile(
    r"(?i)(?<![A-Za-z0-9_.-])(" + _CFG_KEY + r"[\"']?\s*[:=]\s*[\"']?)([^\s\"'`,;&]+)")

_CFG_MIN_LEN = 8
_LOW_ENTROPY = ("bearer", "private-key", "config-secret", "url-credential")


def _is_value_placeholder(value: str) -> bool:
    v = value.strip()
    low = v.lower()
    return (v.startswith("${") or v.startswith("<") or low.startswith("xxx")
            or v.startswith("***") or v.startswith("[REDACTED"))


def _cfg_value_maskable(value: str) -> bool:
    return len(value) >= _CFG_MIN_LEN and not _is_value_placeholder(value)


def _check_version(version: str) -> None:
    if version not in SUPPORTED_VERSIONS:
        raise ValueError(f"unsupported redact ruleset version {version!r}")


def _tag(key: bytes, value: str) -> str:
    return hmac.new(key, value.encode("utf-8", "surrogatepass"), hashlib.sha256).hexdigest()[:8]


def _outside_placeholders(text: str, fn) -> str:
    """Apply fn to every stretch of text that is not an existing placeholder."""
    out = []
    pos = 0
    for m in PLACEHOLDER_RE.finditer(text):
        if m.start() > pos:
            out.append(fn(text[pos:m.start()]))
        out.append(m.group(0))
        pos = m.end()
    if pos < len(text):
        out.append(fn(text[pos:]))
    return "".join(out)


def _one_pass(text: str, key, counts: dict) -> str:
    """One application of every rule, in order. key None = detect only (the
    text is returned unchanged; counts still records every hit)."""

    def bump(kind):
        counts[kind] = counts.get(kind, 0) + 1

    def rule(regex, kind, repl_fn):
        nonlocal text

        def sub(segment):
            def r(m):
                bump(kind)
                return m.group(0) if key is None else repl_fn(m)
            return regex.sub(r, segment)

        text = _outside_placeholders(text, sub)

    rule(_PRIVATE_KEY_RE, "private-key", lambda m: "[REDACTED:private-key]")
    for kind, regex in _TAGGED:
        rule(regex, kind, lambda m, kind=kind: f"[REDACTED:{kind}:{_tag(key, m.group(0))}]")
    rule(_BEARER_RE, "bearer", lambda m: m.group(1) + "[REDACTED:bearer]")
    rule(_URL_CRED_RE, "url-credential",
         lambda m: m.group(1) + "[REDACTED:url-credential]" + m.group(3))

    def cfg(regex, value_group, tail):
        nonlocal text

        def sub(segment):
            def r(m):
                if not _cfg_value_maskable(m.group(value_group)):
                    return m.group(0)
                bump("config-secret")
                if key is None:
                    return m.group(0)
                return m.group(1) + "[REDACTED:config-secret]" + (m.group(3) if tail else "")
            return regex.sub(r, segment)

        text = _outside_placeholders(text, sub)

    cfg(_CFG_JSON_RE, 2, True)
    cfg(_CFG_KV_RE, 2, False)
    return text


_MAX_PASSES = 8


def redact_text(text: str, key: bytes, version: str = RULESET_VERSION) -> tuple[str, dict[str, int]]:
    """Mask every secret in one string. Repeats until nothing changes, so the
    result is a fixed point of the ruleset."""
    _check_version(version)
    if not key:
        raise KeyMissing("hmac key is empty")
    counts: dict[str, int] = {}
    for _ in range(_MAX_PASSES):
        new = _one_pass(text, key, counts)
        if new == text:
            break
        text = new
    return text, counts


# Detection masks a throwaway copy with this key and keeps only the counts, so
# that it sees exactly what redaction would: once a rule has replaced a token, a
# later rule cannot count the same bytes again (`sk-ant-...` is not also an
# openai-key hit).
_DETECT_KEY = b"detect-only"


def _detect_text(text: str, counts: dict) -> None:
    for _ in range(_MAX_PASSES):
        new = _one_pass(text, _DETECT_KEY, counts)
        if new == text:
            break
        text = new


def _dict_key_secret(name, value) -> bool:
    """A str value stored under a secret-looking dict key (`{"password": "..."}`
    in a tool input) is masked whole: the text rules only see `KEY=VALUE`
    spellings inside a string, not the JSON structure around it."""
    return (isinstance(name, str) and isinstance(value, str)
            and _CFG_KEY_RE.fullmatch(name) is not None
            and _cfg_value_maskable(value))


def _walk(record, on_str):
    """Iterative deep copy. on_str(value, dict_key_or_None) returns the new
    string. dicts and lists are copied; every other scalar is shared."""
    holder = [record]
    stack = [(holder, 0, None)]
    while stack:
        parent, k, name = stack.pop()
        v = parent[k]
        if isinstance(v, str):
            parent[k] = on_str(v, name)
        elif isinstance(v, dict):
            new = dict(v)
            parent[k] = new
            for ck in new:
                stack.append((new, ck, ck))
        elif isinstance(v, list):
            new = list(v)
            parent[k] = new
            for i in range(len(new)):
                stack.append((new, i, None))
    return holder[0]


def redact_record(record, key: bytes, version: str = RULESET_VERSION) -> tuple[object, dict[str, int]]:
    """Mask every str value inside a parsed JSON record. The structure (keys,
    nesting, non-string values) is never altered."""
    _check_version(version)
    if not key:
        raise KeyMissing("hmac key is empty")
    counts: dict[str, int] = {}

    def on_str(value, name):
        if _dict_key_secret(name, value):
            counts["config-secret"] = counts.get("config-secret", 0) + 1
            return "[REDACTED:config-secret]"
        masked, c = redact_text(value, key, version)
        for kind, n in c.items():
            counts[kind] = counts.get(kind, 0) + n
        return masked

    return _walk(record, on_str), counts


def detect_record(record, version: str = RULESET_VERSION) -> list[str]:
    """Kinds of secrets still present (unmasked) anywhere in the record, sorted.
    Placeholders are ignored. Used by the server re-scan; returns kind names
    only, never values."""
    _check_version(version)
    counts: dict[str, int] = {}

    def on_str(value, name):
        if _dict_key_secret(name, value):
            counts["config-secret"] = counts.get("config-secret", 0) + 1
        else:
            _detect_text(value, counts)
        return value

    _walk(record, on_str)
    return sorted(counts)


def detect_text(text: str, version: str = RULESET_VERSION) -> list[str]:
    """detect_record for one bare string (the /blob content)."""
    _check_version(version)
    counts: dict[str, int] = {}
    _detect_text(text, counts)
    return sorted(counts)


__all__ = ["RULESET_VERSION", "KeyMissing", "load_key", "redact_record",
           "redact_text", "detect_record", "detect_text", "PLACEHOLDER_RE"]
