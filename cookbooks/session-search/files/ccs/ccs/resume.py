"""`ccs resume SESSION_KEY` (§6.6 Resume).

1. Local file: this host's session and its JSONL exists -> chdir(resume_cwd), exec claude --resume.
2. No local file, archived and archive_complete -> restore the masked archive, then step 1.
   Hardening: the project dir is computed locally (encode(local_cwd)); nothing the
   server sends is used as a path; session_id must match ^[0-9a-f-]{36}$; the
   tool-results tar is extracted member by member with tarfile's `data` filter
   (or an equivalent manual validation on Pythons without it) and every name must
   match TOOL_RESULT_NAME_RE; X-Archive-Sha256 is verified before the rename; a
   different existing file is never overwritten without --force.
3. Otherwise view-only (exit 4 with the reason).
"""

from __future__ import annotations

import hashlib
import io
import os
import re
import shlex
import sys
import tarfile

from . import api as api_mod, config as config_mod, extract, picker, util

RESTORED_NOTE = "restored masked transcript (secrets appear as [REDACTED:…])"


class ResumeError(Exception):
    """Precondition failure -> exit 4."""


def command_line(cwd: str, session_id: str, fork: bool) -> str:
    cmd = "cd %s && claude --resume %s" % (shlex.quote(cwd), shlex.quote(session_id))
    return cmd + (" --fork-session" if fork else "")


def claude_argv(session_id: str, fork: bool):
    return ["claude", "--resume", session_id] + (["--fork-session"] if fork else [])


def exec_claude(cwd: str, session_id: str, fork: bool, do_print: bool, execvp=os.execvp, chdir=os.chdir,
                out=None) -> int:
    out = out or sys.stdout
    if not os.path.isdir(cwd):
        raise ResumeError("resume cwd %s does not exist on this host; not resuming from a different directory"
                          % cwd)
    if do_print:
        out.write(command_line(cwd, session_id, fork) + "\n")
        return util.EXIT_OK
    chdir(cwd)
    execvp("claude", claude_argv(session_id, fork))
    return util.EXIT_OK  # only reached with a stubbed execvp


def validate_session_id(sid) -> str:
    if not isinstance(sid, str) or not util.SESSION_ID_RE.match(sid):
        raise ResumeError("refusing session_id %r: it does not match ^[0-9a-f-]{36}$" % (sid,))
    return sid


def rewrite_tool_result_paths(text: str, original_project_dir: str, session_id: str, new_dir: str) -> str:
    """Point absolute …/.claude/projects/<orig>/<sid>/tool-results/ strings at the restored copy."""
    pat = re.compile(r"(?:/[^\s\"'\\]*)?/\.claude/projects/%s/%s/tool-results/"
                     % (re.escape(original_project_dir), re.escape(session_id)))
    repl = new_dir.rstrip("/") + "/"
    return pat.sub(lambda _m: repl, text)


def _member_ok(m: tarfile.TarInfo) -> bool:
    return m.isfile() and util.TOOL_RESULT_NAME_RE.match(m.name) is not None


def extract_tool_results(tar_bytes: bytes, dest: str) -> int:
    """Extract only regular files with a safe flat name into `dest`. Returns the count."""
    count = 0
    os.makedirs(dest, mode=0o700, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:*") as tf:
        members = tf.getmembers()
        for m in members:
            if not _member_ok(m):
                raise ResumeError("refusing tool-results archive: unsafe member %r" % m.name)
        has_filter = hasattr(tarfile, "data_filter")
        for m in members:
            if has_filter:
                tf.extract(m, dest, filter="data")
            else:
                # Manual equivalent of the data filter for this flat, regular-file-only set.
                target = os.path.join(dest, m.name)
                if os.path.dirname(os.path.realpath(target)) != os.path.realpath(dest):
                    raise ResumeError("refusing tool-results member %r" % m.name)
                src = tf.extractfile(m)
                data = src.read() if src else b""
                fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0), 0o600)
                with os.fdopen(fd, "wb") as fh:
                    fh.write(data)
            count += 1
    return count


def _file_sha(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def choose_cwd(meta: dict, to_dir: str | None, ask=input, isatty=None) -> str:
    rc = meta.get("resume_cwd")
    if isinstance(rc, str) and rc.startswith("/") and os.path.isdir(rc):
        return rc
    if to_dir:
        d = os.path.abspath(os.path.expanduser(to_dir))
        if not os.path.isdir(d):
            raise ResumeError("--to %s is not a directory" % to_dir)
        return d
    here = os.getcwd()
    tty = sys.stdin.isatty() if isatty is None else isatty
    if not tty:
        return here
    ans = ask("original cwd %s is not on this host; resume in [%s]: " % (rc or "?", here)).strip()
    d = os.path.abspath(os.path.expanduser(ans)) if ans else here
    if not os.path.isdir(d):
        raise ResumeError("%s is not a directory" % d)
    return d


def restore(api, meta: dict, local_cwd: str, force: bool, session_key: str, out=None) -> str:
    """Download + verify + place the masked archive. Returns the session_id."""
    out = out or sys.stderr
    sid = validate_session_id(meta.get("session_id"))
    proj = util.encode_cwd(local_cwd)
    pdir = os.path.join(util.projects_dir(), proj)
    target = os.path.join(pdir, sid + ".jsonl")
    tmp = target + ".tmp"
    resp = api.get("/archive", params={"session_key": session_key}, timeout=120)
    if resp.status == 409:
        data = resp.json() or {}
        raise ResumeError("archive refused by the server: %s" % (data.get("error") or "conflict"))
    if resp.status != 200:
        raise ResumeError("archive download answered HTTP %d" % resp.status)
    want = (resp.header("X-Archive-Sha256") or "").strip().lower()
    got = hashlib.sha256(resp.body).hexdigest()
    if not re.match(r"^[0-9a-f]{64}$", want) or want != got:
        raise ResumeError("archive sha256 mismatch (header %s, body %s); nothing restored" % (want or "missing", got))
    tr_dir = os.path.join(pdir, sid, "tool-results")
    orig_proj = meta.get("project_dir") if isinstance(meta.get("project_dir"), str) else ""
    text = resp.body.decode("utf-8", "replace")
    if orig_proj:
        text = rewrite_tool_result_paths(text, orig_proj, sid, tr_dir)
    data = text.encode("utf-8")
    if os.path.exists(target) and not force:
        if hashlib.sha256(data).hexdigest() != _file_sha(target):
            raise ResumeError("%s already exists and differs from the archive; pass --force to replace it" % target)
    os.makedirs(pdir, mode=0o700, exist_ok=True)
    try:
        with open(tmp, "wb") as fh:
            fh.write(data)
        tres = api.get("/archive/tool-results", params={"session_key": session_key}, timeout=120)
        if tres.status == 200 and tres.body:
            extract_tool_results(tres.body, tr_dir)
        elif tres.status not in (200, 404):
            raise ResumeError("tool-results download answered HTTP %d" % tres.status)
        os.replace(tmp, target)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    out.write(RESTORED_NOTE + "\n")
    return sid


def _local_session(path: str) -> dict:
    ls = extract.scan(path)
    return {"session_id": ls.session_id, "resume_cwd": ls.resume_cwd, "jsonl_path": path,
            "host": None, "jsonl_exists": True}


def resume(session_key: str, do_print: bool = False, fork: bool = False, to_dir: str | None = None,
           force: bool = False, api_factory=None, execvp=os.execvp, chdir=os.chdir, ask=input, out=None) -> int:
    out = out or sys.stdout
    try:
        if session_key.startswith("local:"):
            path = session_key[len("local:"):]
            if not os.path.isfile(path):
                raise ResumeError("local transcript %s no longer exists" % path)
            meta = _local_session(path)
            validate_session_id(meta["session_id"])
            return exec_claude(meta["resume_cwd"], meta["session_id"], fork, do_print, execvp, chdir, out)
        try:
            cfg = config_mod.load()
        except config_mod.ConfigError as e:
            sys.stderr.write("ccs: %s\n" % e)
            return util.EXIT_UNREACHABLE
        api = (api_factory or api_mod.Api)(cfg)
        try:
            resp = api.get("/preview", params={"session_key": session_key, "q": ""}, timeout=10)
        except (api_mod.Unreachable, api_mod.AuthError) as e:
            sys.stderr.write("ccs: server unreachable: %s\n" % e)
            return util.EXIT_UNREACHABLE
        if resp.status == 404:
            raise ResumeError("unknown session_key %s" % session_key)
        if resp.status != 200:
            sys.stderr.write("ccs: preview answered HTTP %d\n" % resp.status)
            return util.EXIT_UNREACHABLE
        meta = (resp.json() or {}).get("session") or {}
        sid = validate_session_id(meta.get("session_id"))
        jp = meta.get("jsonl_path")
        if meta.get("host") == cfg.host_label and isinstance(jp, str) and os.path.isfile(jp):
            cwd = meta.get("resume_cwd") or ""
            return exec_claude(cwd, sid, fork, do_print, execvp, chdir, out)
        if meta.get("archived") and meta.get("archive_complete"):
            local_cwd = choose_cwd(meta, to_dir, ask=ask)
            try:
                sid = restore(api, meta, local_cwd, force, session_key)
            except api_mod.Unreachable as e:
                sys.stderr.write("ccs: server unreachable: %s\n" % e)
                return util.EXIT_UNREACHABLE
            return exec_claude(local_cwd, sid, fork, do_print, execvp, chdir, out)
        raise ResumeError("view-only: %s" % (picker.view_only_reason(meta, cfg.host_label) or "not resumable"))
    except ResumeError as e:
        sys.stderr.write("ccs: %s\n" % e)
        return util.EXIT_RESUME
