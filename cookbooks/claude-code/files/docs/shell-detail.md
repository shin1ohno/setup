# Shell Script Guidelines — Examples & Origin Notes

On-demand detail for `~/ManagedProjects/setup/.claude/rules/shell.md`. Read a section when the summary points here.


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

## zsh / harness `!` mangling — inline `!` can corrupt (jq `!=` and beyond)

An inline `!` passed through the Claude Code Bash tool can arrive mangled to `\!`. This is NOT limited to the jq `!=` operator: in the 2026-06 window the same class fired 3 times across 2 repos — (i) setup 2026-06-12, a `reject!` Ruby method inside a single-quoted heredoc body was corrupted; (ii) zp-SHIN 2026-06-16, a JS `!==` inside a heredoc was corrupted; (iii) zp-SHIN 2026-06-27, `printf '%s\n' '<!-- ... -->' >> file` silently wrote `<\!--` into the file (no error; the corruption survived into the committed artifact).

**Mechanism (corrected)**: the command shown in the transcript is clean and only the *executed result* carries the `\!` — so this is NOT zsh history expansion (which is inert inside single quotes). It is a `!`-escape at the harness layer, BEFORE the string reaches any shell. Therefore quote form, a `/bin/bash -c` wrapper, and a single-quoted heredoc do NOT prevent it — all of those live below the harness layer.

**Current status (keep this note fresh)**: a 2026-07-06 probe reproduced NONE of the above (the 3 shapes + jq `!=`) — likely a harness fix. So this is a version-dependent known class, NOT an always-breaks rule; do NOT mechanically ban inline `!`.

**jq case (still the most common trigger)**: when TEST-ing a jq filter interactively via the Bash tool, prefer the `| not` form over `!=` / bare `!`:

- `.field != "value"` → `(.field == "value" | not)`
- any `select(... != ...)` held in a shell var → phrase the negation with `| not`

The deployed script (bash, no history expansion) runs the original `!=` filter fine, so `| not` mainly makes the interactive test match the runtime.

**Detection recipe**: right after writing `!`-containing content through the shell, byte-verify with `od -c <file>` or `grep -n '\\!' <file>` before committing. If you observe `\!`, switch to the Write/Edit tool to place the literal/script (all 3 sessions recovered via Write/Edit).

Origin: 2026-06-28 zp-issue-loops merge-gate — `JQ='... (.mergeStateStatus != "CLEAN") ...'` mangled to `\!=` in the Bash tool while the launchd runner ran the identical filter cleanly; rephrased as `(.mergeStateStatus == "CLEAN" | not)`. Extended 2026-06 by the 3 heredoc/printf cases above. The candidate claim that a loop-body shell negation `! rg -q …` also corrupts is NOT included — no evidence, not reproduced.

## chain-two-sudo

## Never Chain Two `sudo` Calls in a `!` Block

```
# Anti-pattern — second sudo silently doesn't run if its prompt isn't visible
! sudo dpkg-divert --rename --add /usr/sbin/resolvconf && sudo systemctl restart tailscaled
```

The first `sudo` succeeds with password entry. The second `sudo` may either re-prompt (because the timestamp cache wasn't propagated through the chain in the user's shell) or appear to skip silently in the buffered terminal output. Either way, the user often sees only the first command's success message and assumes the chain completed. Diagnosing the silent skip costs a round-trip.

Instead, split into numbered `!` items the user runs sequentially:

```
1. ! sudo dpkg-divert --rename --add /usr/sbin/resolvconf
2. ! sudo systemctl restart tailscaled
```

Each gets its own clean prompt and visible result. The user can re-run any step in isolation if needed.

Origin: 2026-04-26 — chained `sudo ... && sudo ...` `!` block, second sudo silently skipped.

## ssh-while-read-drains-stdin

## SSH inside `while-read` Loop Drains Parent Stdin

**Wrong** (consumes pipe — silently skips host #2 onward):

```bash
while IFS= read -r entry; do
    host=$(jq -r '.host' <<<"$entry")
    output=$(ssh -i key root@"$host" "$cmd")  # ← reads parent stdin, drains pipe
    ...
done < <(jq -c '.[]' "$HOSTS_JSON")
```

**Right** — pass `-n` (or `< /dev/null`) so ssh's stdin goes to /dev/null and the parent pipe stays intact:

```bash
while IFS= read -r entry; do
    host=$(jq -r '.host' <<<"$entry")
    output=$(ssh -n -i key root@"$host" "$cmd")
    ...
done < <(jq -c '.[]' "$HOSTS_JSON")
```

Origin: 2026-05-06 PR #153 — bare ssh in jq-fed read loop dropped all hosts but the first.

## multi-hop-shell-injection

## Multi-hop Shell Injection (ssh → pct exec → bash)

When running commands inside a PVE LXC via `ssh host 'pct exec <vmid> -- bash -c "..."'`, the command string traverses **three quoting layers** before reaching the inner bash:

1. The local shell (this machine) interprets the outer single quotes
2. The remote ssh shell (PVE host) interprets `pct exec ... -- bash -c "..."` — the `bash -c` argument is the double-quoted string
3. The container's bash (CT) executes the contents of the double-quoted string

Shell metacharacters — `()`, `$()`, backticks, `!` history expansion, `*` glob — inside the innermost string are interpreted at layer 2 (the remote ssh shell), NOT inside the container. This causes silent breakage:

```
ssh root@pve.host 'pct exec 111 -- bash -c "
  echo === step 1.3: bin/setup (mitamae binary download) ===
  ...
"'
# Layer 2 evaluates `(mitamae binary download)` as a subshell call to
# the command `mitamae`, fails with `mitamae: command not found` (or
# `syntax error near unexpected token (` when nested) — and the rest
# of the multi-line block silently doesn't run.
```

**Clean pattern — single-quoted heredoc piped to `bash -s`**:

```
ssh root@pve.host "pct exec 111 -- bash -s" <<'EOF'
set -euo pipefail
echo === step 1.3: bin/setup (mitamae binary download) ===
cd /root/setup && ./bin/setup
EOF
```

Why this works:

- The outer `"..."` only wraps the ssh command-line — no metacharacter interpretation inside the command body
- `<<'EOF'` (single-quoted delimiter) tells the local shell to send the heredoc content **verbatim** with no expansion of `$VAR`, `$()`, `()`, backticks, or `!`
- `bash -s` reads from stdin (the heredoc) instead of taking a `-c` argument, so the inner bash sees the script source character-for-character

**Same trap fires for direct (non-nested) `bash -c '...'` too**: any `()` inside the single-quoted body — typically commentary parentheses in `echo === foo (bar) ===` — is interpreted as subshell grouping by the inner bash. Both forms break:

```
bash -c 'echo === foo (bar) ==='
# bash: -c: line 1: syntax error near unexpected token '('

ssh host 'echo === foo (bar) ==='
# Same error at the remote shell, before reaching anything else
```

Fix options (any work):

- Drop the parens: `echo === foo bar ===`
- Escape: `echo "=== foo (bar) ==="` (use double quotes outside, or escape `\(\)`)
- Heredoc: `bash <<'EOF' ... EOF` (no -c argument)

Origin: 2026-05-06 / 2026-05-11 / 2026-06-07 — `syntax error near unexpected token '('` from commentary parens in `echo === ... ===` headers through three remote shells; structural, recurs per metacharacter unless heredoc + `bash -s` is the default.

## awk-dollar-bash-positional-collision

## `awk $N` vs bash positional parameters inside a quoted `bash -c`

The failing shape: a script is already committed to `bash -c '…'` — most often because it needs `set -euo pipefail`, which dash rejects as a bare mitamae `command` (see the pipefail rule in `~/ManagedProjects/setup/.claude/rules/ruby.md` / the `bash -c` wraps in `cookbooks/{codex-cli,mcp,herdr,terraform}`). Single quotes are therefore unavailable inside, so an awk program gets written in double quotes:

```bash
bash -c 'ssh-keygen -lf "$TMP" | awk "{print \$2}" | sort'
```

Bash parses `$2` as its own positional parameter and substitutes empty **before awk is invoked**, so awk receives `{print }`. `$10` degrades differently — `$1` followed by a literal `0`.

**Why nothing catches it**: `ruby -c`, `bash -n`, `mitamae --dry-run`, and the outer shell's own parse all pass, because every layer's syntax IS valid. Only the runtime value is wrong, and the pipeline still exits 0. It surfaces as an empty or shifted field downstream — e.g. a fingerprint comparison that always mismatches, or a variable that is silently blank.

`cut` sidesteps the class entirely (no `$`-prefixed field syntax):

```bash
cut -d' ' -f2
grep "^fpr:" | cut -d: -f10   # replaces awk -F: '/^fpr:/ {print $10}'
```

For logic `cut` cannot express, ship the program as `files/<name>.awk` via `remote_file` and invoke `awk -f`, removing inline quoting from the problem entirely.

Origin: 2026-08-01 sh1-cloud `gcp-ssh-keys` cookbook (zp-SHIN #111) — a github.com `known_hosts` keyscan needed field 2 of `ssh-keygen -lf` output for fingerprint verification, inside a `bash -c` wrapper the `set -euo pipefail` forced. Caught by rendering the cookbook through a stub DSL and executing the extracted script, not by any syntax check.

## sed-awk-over-python3

## Prefer sed/awk over `python3 -c` for inline filesystem edits

**Concrete substitutions**:

| Task | python3 -c (avoid) | sed/awk (prefer) |
|---|---|---|
| Remove INI section `[name]` and its body | `python3 -c "import configparser; c=configparser.ConfigParser(); c.read('f'); c.remove_section('name') if 'name' in c else None; c.write(open('f','w'))"` | `sed -i.bak '/^\[name\]$/,/^\[/{/^\[name\]$/d; /^\[/!d}' f` |
| Replace value of `key = ...` in INI | `python3 -c "..."` (multi-line) | `sed -i 's/^key = .*/key = newvalue/' f` |
| Filter JSON one key | (Python possible) | `jq '.key' f` (preferred over either) |
| Edit YAML | (Python possible) | `yq` if available, else sed for simple cases |

Origin: 2026-05-11 — multi-line `python3 -c` paste-broke with `IndentationError`; one sed command worked first try.
