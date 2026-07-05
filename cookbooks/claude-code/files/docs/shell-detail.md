# Shell Script Guidelines — Examples & Origin Notes

On-demand detail for `~/.claude/rules/shell.md`. Read a section when the summary points here.


## awk-bwk-vs-gawk

## awk Cross-platform Pitfalls (BWK vs gawk)

`awk -v VAR=value` looks portable BUT **macOS BWK awk rejects literal newlines inside `-v` values**, while Linux gawk accepts them. CI runs on Linux → bug invisible. mitamae apply on Mac → `awk: newline in string` with exit 2.

Trap (real, 2026-05-11 setup PR #330):

```bash
ES_HOSTS_YAML="    - https://es-0...
    - https://es-1...
    - https://es-2..."

awk -v hosts="${ES_HOSTS_YAML}" '{ ... }'   # OK on Linux gawk, FAILS on macOS BWK
```

**Fixes** (pick by context):

1. **Temp file pattern** (most portable, no escape traps):

```bash
HOSTS_FILE=$(mktemp)
trap 'rm -f "${HOSTS_FILE}"' EXIT
printf '%s\n' "${ES_HOSTS_YAML}" > "${HOSTS_FILE}"
awk -v hosts_file="${HOSTS_FILE}" '
{
    if ($0 ~ /@@MARKER@@/) {
        while ((getline line < hosts_file) > 0) print line
        close(hosts_file)
    } else { print }
}' "$TEMPLATE"
```

2. **stdin via pipe** (when the value IS the awk input):

```bash
printf '%s\n' "${MULTI_LINE}" | awk '{ ... }'
```

3. **Replace newlines with a sentinel + split inside awk** (when the value is one of several `-v` inputs):

```bash
awk -v hosts="$(printf '%s' "${MULTI_LINE}" | tr '\n' '\036')" \
    'BEGIN { n = split(hosts, a, "\036") } { ... }'
```

Default to the **temp file pattern**. Other approaches accumulate escape complexity. `-v` values with a single embedded newline can sometimes pass on Mac too — do not rely on this; treat any multi-line `-v` value as unsupported.

**Plan-time detection**: any cookbook with a multi-line shell variable feeding `awk -v` must be tested with macOS BWK awk before merge. `bash -n` does not catch this; the failure surfaces only at runtime under mac awk. CI on Linux gawk is also blind to it.

Origin: 2026-05-11 PR #330 — multi-line `awk -v` passed Linux CI, failed macOS BWK with `awk: newline in string`. Fix: temp file pattern in `cookbooks/elastic-agent/files/generate_config.sh`.

## macos-external-command-audit

## macOS External-Command Audit for Ported Linux Scripts

`bash -n`, `ruby -c`, and `mitamae --dry-run` check syntax and resource placement only — they do NOT verify that external commands exist on the target OS. A script using a Linux-only command passes all static checks and misfires silently at runtime.

**Trigger**: any shell script deployed by a cookbook that runs on macOS (`darwin.rb`, any `air` / `ohnos-macbook` role) that was written or tested on Linux.

Before shipping, grep the script for Linux-only commands:

```bash
grep -E '\b(flock|timeout|gtimeout|sponge|tac|nproc|numfmt|realpath|readlink)\b' <script>
```

**Silent-failure trap for `flock`**: `if ! flock …` reads exit 127 (command not found) as truthy → the script logs "another run holds the lock" and silently skips. This is NOT an error; it is a false skip that persists every run (looks like normal lock contention).

macOS-native replacements:

- `flock` → `mkdir` + PID lock: `if ! mkdir "$LOCKDIR" 2>/dev/null; then exit 0; fi; trap 'rm -rf "$LOCKDIR"' EXIT; echo $$ > "$LOCKDIR/pid"` (stale lock: `kill -0` the recorded PID, steal only if the holder is dead)
- `timeout N cmd` → background watchdog: `cmd & PID=$!; (sleep N; kill -TERM $PID 2>/dev/null) & wait $PID`
- `realpath` / `readlink -f` → `$(cd "$(dirname "$f")"; pwd)/$(basename "$f")`

Static check alone is insufficient — run the script once on the target OS before declaring the cookbook done.

Origin: 2026-06-27 zp-SHIN issue/PR loop (mercari-setup overlay) — `flock` / `timeout` absent on macOS; `if ! flock` silently misfired as "lock held" every run; passed `bash -n` + `mitamae --dry-run`, surfaced only at runtime on `air`.

## zsh-bang-history-expansion

## zsh History Expansion Mangles `!=` in Interactive jq — Avoid `!` in tested filters

When writing a jq filter you will TEST interactively via the Claude Code Bash tool (which runs under the user's zsh), avoid the `!=` operator and bare `!`. zsh history expansion rewrites `!=` to `\!=` even inside a **single-quoted** multi-line variable assignment (`JQ='... .x != "y" ...'`), producing `jq: syntax error ... INVALID_CHARACTER` that does NOT reproduce in non-interactive bash (launchd, cron, `bash -c`, a `#!/usr/bin/env bash` script). The failure is therefore invisible in the actual runtime and only breaks your interactive unit test — a wasted cycle chasing a non-bug.

Rewrite to drop the `!`:

- `.field != "value"` → `(.field == "value" | not)`
- any `select(... != ...)` embedded in a shell-var-held filter → phrase the negation with `| not`

The deployed script (bash, no history expansion) runs the original filter fine; this is purely an interactive-test artifact, but rephrasing with `| not` makes the test match the runtime.

Origin: 2026-06-28 zp-issue-loops merge-gate — `JQ='... (.mergeStateStatus != "CLEAN") ...'` was mangled to `\!=` in the Bash tool (zsh) and failed jq compile; the launchd runner ran the identical filter cleanly. Rephrased as `(.mergeStateStatus == "CLEAN" | not)`.
