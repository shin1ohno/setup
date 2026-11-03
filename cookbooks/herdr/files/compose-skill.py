#!/usr/bin/env python3
"""Patch the pinned upstream skill, failing closed if its context gate changes."""
from pathlib import Path
import subprocess
import sys


def compose(upstream, local):
    start = upstream.index("Before issuing any control command,")
    end = upstream.index("## Learn the current CLI", start)
    gate = """Before controlling terminals, verify the caller with the managed helper:

```bash
python3 ~/.agents/skills/herdr/caller-context.py resolve
```

If inherited foreground ancestry cannot be verified (including shared Codex
app-server tools without HERDR_*), run `prepare`, then `verify` in **two separate
tool calls**. The first call displays a one-use session challenge; the second
matches it against live Codex pane output and unchanged foreground processes.
Do not copy the challenge to any other pane. Verification expires after 120
seconds; absent, duplicate, stale or replaced callers fail closed. It sends no
terminal input. A failed check means **caller unverified**, not “outside Herdr”.
Do not export invented HERDR_* values or use focused pane, cwd/title matches,
`pane current --current`, a ledger ID, or a user's assertion as identity proof.

Use the returned `session`, `socket`, `pane_id`, `workspace_id` and `tab_id`.
Pass `--session <verified-session>` and explicit `--pane <verified-pane>` (or
the command's positional pane ID) on subsequent local commands. Reverify after
an interruption, move, session switch or process replacement. Inspect IDs
returned by creation commands for new targets. Do not use `--current` when
HERDR_* is missing: it may select the UI-focused pane. Never retarget remote
commands using this local proof. If verification fails, stop control commands
and report the observed blocker; do not inspect an unrelated focused session.

"""
    upstream = upstream[:start] + gate + upstream[end:]
    upstream = upstream.replace("Requires HERDR_ENV=1.", "Requires verified caller context.")
    start = upstream.index("Herdr injects the caller's context")
    end = upstream.index("Creation responses expose", start)
    upstream = upstream[:start] + "Use the verified helper result for caller IDs. Discover live state with an explicit verified session and workspace; never infer caller identity from focus.\n\n" + upstream[end:]
    # Examples must not restore the unsafe implicit-current fallback.
    # Replace command examples only, preserving the warning about --current.
    upstream = upstream.replace("herdr pane split --current", "herdr --session <verified-session> pane split --pane <verified-caller-pane>")
    upstream = upstream.replace('"$HERDR_PANE_ID"', '"<verified-caller-pane>"')
    return upstream + "\n" + local


if __name__ == "__main__":
    upstream = subprocess.check_output([sys.argv[1], "--skill"], text=True)
    print(compose(upstream, Path(sys.argv[2]).read_text()), end="")
