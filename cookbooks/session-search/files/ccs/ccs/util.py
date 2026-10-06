"""Paths, logging, atomic writes and small parsers shared by every ccs command.

Every path is derived from $HOME at call time (not import time) so tests can
point HOME at a temporary directory.
"""

from __future__ import annotations

import datetime as _dt
import json
import os
import re
import tempfile

# Exit codes (§7.4).
EXIT_OK = 0
EXIT_USAGE = 2
EXIT_UNREACHABLE = 3
EXIT_RESUME = 4

SESSION_ID_RE = re.compile(r"^[0-9a-f-]{36}$")
# Names accepted for tool-results side files, both when shipping (/blob) and
# when extracting the restore tar. Claude Code writes `<tool_use_id>.txt`-style
# names; anything with a path separator, a leading dot or odd bytes is refused.
TOOL_RESULT_NAME_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$")
HOST_LABEL_RE = re.compile(r"^[a-z0-9-]{1,63}$")


def home() -> str:
    return os.path.expanduser("~")


def claude_dir() -> str:
    return os.path.join(home(), ".claude")


def projects_dir() -> str:
    return os.path.join(claude_dir(), "projects")


def state_dir() -> str:
    return os.path.join(claude_dir(), "session-search")


def state_path() -> str:
    return os.path.join(state_dir(), "state.json")


def lock_path() -> str:
    return os.path.join(state_dir(), "lock")


def breaker_path() -> str:
    return os.path.join(state_dir(), "breaker.json")


def log_path() -> str:
    return os.path.join(claude_dir(), "session-search.log")


def config_path() -> str:
    return os.environ.get("CCS_CONFIG") or os.path.join(home(), ".config", "session-search", "config.json")


def encode_cwd(cwd: str) -> str:
    """Claude Code's project-directory encoding (§6.1; 210/210 measured in Phase 0)."""
    return re.sub(r"[^A-Za-z0-9-]", "-", cwd)


def ensure_dir(path: str, mode: int = 0o700) -> None:
    os.makedirs(path, mode=mode, exist_ok=True)


def atomic_write(path: str, data: str, mode: int = 0o600) -> None:
    """Write via a temp file in the same directory, then rename into place."""
    d = os.path.dirname(path) or "."
    ensure_dir(d)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(data)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_json(path: str, default):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def now_utc() -> _dt.datetime:
    return _dt.datetime.now(_dt.timezone.utc)


def iso(ts: _dt.datetime) -> str:
    return ts.astimezone(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(level: str, msg: str) -> None:
    """Append one line to ~/.claude/session-search.log.

    Callers pass metadata only (paths, counts, status codes, kinds) — never
    transcript text or secrets.
    """
    line = "%s %s %s\n" % (iso(now_utc()), level, msg.replace("\n", " "))
    try:
        ensure_dir(claude_dir(), 0o755)
        with open(log_path(), "a", encoding="utf-8") as fh:
            fh.write(line)
    except OSError:
        pass


_DUR_RE = re.compile(r"^([1-9][0-9]{0,5})([mhdw])$")
_DUR_UNIT = {"m": 60, "h": 3600, "d": 86400, "w": 7 * 86400}


def parse_duration(text: str) -> int:
    """`7d` -> seconds. Raises ValueError on anything else."""
    m = _DUR_RE.match(text or "")
    if not m:
        raise ValueError("duration must look like 30m, 12h, 7d or 2w: %r" % text)
    return int(m.group(1)) * _DUR_UNIT[m.group(2)]


def parse_ts(value) -> float | None:
    """ISO-8601 (with Z or offset) -> epoch seconds; None when unparsable."""
    if not isinstance(value, str) or not value:
        return None
    v = value.strip()
    if v.endswith("Z"):
        v = v[:-1] + "+00:00"
    # Python 3.9's fromisoformat does not accept fractional seconds of every width.
    m = re.match(r"^(.*T\d{2}:\d{2}:\d{2})(\.\d+)?(.*)$", v)
    if m:
        frac = (m.group(2) or "")[:7].ljust(7, "0") if m.group(2) else ""
        v = m.group(1) + frac + m.group(3)
    try:
        dt = _dt.datetime.fromisoformat(v)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=_dt.timezone.utc)
    return dt.timestamp()


def human_age(seconds: float) -> str:
    s = max(0, int(seconds))
    if s < 3600:
        return "%dm" % (s // 60)
    if s < 86400:
        return "%dh" % (s // 3600)
    if s < 86400 * 60:
        return "%dd" % (s // 86400)
    return "%dmo" % (s // (86400 * 30))


def short_cwd(cwd: str, width: int = 28) -> str:
    if not cwd:
        return "?"
    h = home()
    if cwd == h or cwd.startswith(h + os.sep):
        cwd = "~" + cwd[len(h):]
    if len(cwd) <= width:
        return cwd
    return "…" + cwd[-(width - 1):]
