"""Command line (§7.4).

    ccs [QUERY] [--deep] [--semantic] [--all] [--sidechain] [--here] [--host H]... [--since DUR]
                [--offline] [--print] [--fork]
    ccs resume SESSION_KEY [--print] [--fork] [--to DIR] [--force]
    ccs ingest (--file PATH [--with-subagents] | --sweep | --backfill) [--quiet]
    ccs status
    ccs purge SESSION_KEY
    ccs _backend Q / ccs _preview KEY Q          internal (fzf callbacks)
    ccs _toggle LETTER / ccs _fuse SEQ Q          internal (fzf toggles, semantic debounce)

Exit codes: 0 success or cancelled picker, 2 usage error, 3 server unreachable and
the fallback unusable, 4 resume precondition failure.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

from . import VERSION, util

SUBCOMMANDS = ("resume", "ingest", "status", "purge", "_backend", "_preview", "_toggle", "_fuse")


class _Parser(argparse.ArgumentParser):
    """argparse already exits 2 on a usage error; keep that, but never print a traceback."""


def picker_parser():
    p = _Parser(prog="ccs", description="Search Claude Code sessions and resume one.")
    p.add_argument("query", nargs="*", help="initial query")
    p.add_argument("--deep", action="store_true", help="include tool_text (ctrl-d toggles)")
    p.add_argument("--semantic", action="store_true", help="hybrid ranking from the first query (ctrl-s toggles)")
    p.add_argument("--all", action="store_true", help="include headless sdk-* sessions (ctrl-a toggles)")
    p.add_argument("--sidechain", action="store_true", help="include subagent messages")
    p.add_argument("--here", action="store_true", help="restrict to sessions whose cwd is under $PWD")
    p.add_argument("--host", action="append", default=[], metavar="H", help="restrict to one host (repeatable)")
    p.add_argument("--since", metavar="DUR", help="e.g. 7d, 30d; default: unlimited")
    p.add_argument("--offline", action="store_true", help="force the local rg fallback")
    p.add_argument("--print", dest="do_print", action="store_true",
                   help="print `cd <cwd> && claude --resume <id>` instead of exec (ctrl-y)")
    p.add_argument("--fork", action="store_true", help="pass --fork-session to claude")
    p.add_argument("--version", action="version", version="ccs " + VERSION)
    return p


def sub_parser(cmd: str):
    p = _Parser(prog="ccs " + cmd)
    if cmd == "resume":
        p.add_argument("session_key")
        p.add_argument("--print", dest="do_print", action="store_true")
        p.add_argument("--fork", action="store_true")
        p.add_argument("--to", metavar="DIR")
        p.add_argument("--force", action="store_true")
    elif cmd == "ingest":
        g = p.add_mutually_exclusive_group(required=True)
        g.add_argument("--file", metavar="PATH")
        g.add_argument("--sweep", action="store_true")
        g.add_argument("--backfill", action="store_true")
        p.add_argument("--with-subagents", action="store_true")
        p.add_argument("--quiet", action="store_true")
    elif cmd == "purge":
        p.add_argument("session_key")
    elif cmd == "_backend":
        p.add_argument("q", nargs="?", default="")
    elif cmd == "_preview":
        p.add_argument("key")
        p.add_argument("q", nargs="?", default="")
    elif cmd == "_toggle":
        p.add_argument("letter", choices=list("sda"))
    elif cmd == "_fuse":
        p.add_argument("seq")
        p.add_argument("q", nargs="?", default="")
    return p


def parse(argv):
    """-> (command, namespace). Raises SystemExit(2) on a usage error."""
    argv = list(argv)
    if argv and argv[0] in SUBCOMMANDS:
        cmd = argv.pop(0)
        p = sub_parser(cmd)
        ns = p.parse_args(argv)
        if cmd == "ingest" and ns.with_subagents and not ns.file:
            p.error("--with-subagents needs --file")
        return cmd, ns
    if argv and argv[0] == "--":
        argv = argv[1:]
    p = picker_parser()
    ns = p.parse_args(argv)
    if ns.since:
        try:
            ns.since_seconds = util.parse_duration(ns.since)
        except ValueError as e:
            p.error(str(e))
    else:
        ns.since_seconds = None
    for h in ns.host:
        if not util.HOST_LABEL_RE.match(h):
            p.error("--host %r is not a host label" % h)
    return "pick", ns


def pick_options(ns) -> tuple:
    flags = set()
    if ns.semantic:
        flags.add("s")
    if ns.deep:
        flags.add("d")
    if getattr(ns, "all"):
        flags.add("a")
    opts = {"sidechain": ns.sidechain, "offline": ns.offline}
    if ns.here:
        opts["cwd_prefix"] = os.getcwd()
    if ns.host:
        opts["hosts"] = ns.host
    if ns.since_seconds:
        import datetime as _dt

        opts["since"] = util.iso(util.now_utc() - _dt.timedelta(seconds=ns.since_seconds))
    return flags, opts


def cmd_status(out=None) -> int:
    from . import api as api_mod, config as config_mod, ingest

    out = out or sys.stdout
    try:
        cfg = config_mod.load()
    except config_mod.ConfigError as e:
        out.write("config: %s\n" % e)
        cfg = None
    if cfg:
        out.write("endpoint:   %s\nhost_label: %s\nauth:       %s\nconfig:     %s\n"
                  % (cfg.endpoint, cfg.host_label, cfg.auth_type, cfg.path))
        key_ok = os.path.isfile(cfg.hmac_key_file) and os.path.getsize(cfg.hmac_key_file) > 0
        out.write("hmac key:   %s\n" % ("present" if key_ok else "MISSING — ingest is fail-closed"))
    br = api_mod.Breaker().state()
    out.write("breaker:    %s (failures=%d)\n" % ("OPEN" if br["open"] else "closed", br["failures"]))
    st = ingest.State()
    lag, tracked = 0, 0
    for path, e in st.files.items():
        tracked += 1
        try:
            lag += max(0, os.path.getsize(path) - int(e.get("offset", 0)))
        except OSError:
            pass
    untracked = [p for p in ingest.discover() if p not in st.files]
    out.write("cursor lag: %d bytes over %d tracked files; %d files never shipped\n" % (lag, tracked, len(untracked)))
    code = util.EXIT_OK
    if cfg:
        try:
            resp = api_mod.Api(cfg, timeout=3).get("/status")
            body = resp.json()
            out.write("server:     HTTP %d %s\n" % (resp.status, json.dumps(body, sort_keys=True) if body else ""))
            if resp.status != 200:
                code = util.EXIT_UNREACHABLE
        except (api_mod.Unreachable, api_mod.AuthError, config_mod.ConfigError) as e:
            out.write("server:     unreachable (%s)\n" % e)
            code = util.EXIT_UNREACHABLE
    out.write("last errors:\n")
    for line in _last_errors():
        out.write("  " + line + "\n")
    return code


def _last_errors(n: int = 8):
    try:
        with open(util.log_path(), encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()[-2000:]
    except OSError:
        return []
    return [ln.rstrip("\n") for ln in lines if " WARN " in ln or " ERROR " in ln][-n:]


def cmd_purge(key: str) -> int:
    from . import api as api_mod, config as config_mod

    try:
        cfg = config_mod.load()
        resp = api_mod.Api(cfg).request("DELETE", "/session", params={"session_key": key})
    except config_mod.ConfigError as e:
        sys.stderr.write("ccs: %s\n" % e)
        return util.EXIT_UNREACHABLE
    except (api_mod.Unreachable, api_mod.AuthError) as e:
        sys.stderr.write("ccs: server unreachable: %s\n" % e)
        return util.EXIT_UNREACHABLE
    if resp.status != 200:
        sys.stderr.write("ccs: purge answered HTTP %d\n" % resp.status)
        return util.EXIT_UNREACHABLE
    print(json.dumps(resp.json(), sort_keys=True))
    return util.EXIT_OK


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    try:
        cmd, ns = parse(argv)
    except SystemExit as e:
        return int(e.code) if isinstance(e.code, int) else util.EXIT_USAGE
    if cmd == "pick":
        from . import picker

        flags, opts = pick_options(ns)
        return picker.run(" ".join(ns.query), flags, opts, ns.do_print, ns.fork)
    if cmd == "resume":
        from . import resume

        return resume.resume(ns.session_key, do_print=ns.do_print, fork=ns.fork, to_dir=ns.to, force=ns.force)
    if cmd == "ingest":
        from . import ingest

        mode = "file" if ns.file else ("sweep" if ns.sweep else "backfill")
        return ingest.run(mode, file_path=ns.file, with_subagents=ns.with_subagents, quiet=ns.quiet)
    if cmd == "status":
        return cmd_status()
    if cmd == "purge":
        return cmd_purge(ns.session_key)
    from . import picker

    if cmd == "_backend":
        return picker.backend(ns.q)
    if cmd == "_preview":
        return picker.preview(ns.key, ns.q)
    if cmd == "_toggle":
        print(picker.toggle(ns.letter))
        return util.EXIT_OK
    if cmd == "_fuse":
        return picker.fuse(ns.seq, ns.q)
    return util.EXIT_USAGE  # pragma: no cover
