---
globs: ["*.sh", "*.zsh", "*.bash"]
---

# Shell Script Guidelines

## Locality Check Before Assuming Remote

Before writing any command that assumes a target host is remote (ssh, scp, rsync over ssh, `gh api` to a remote server, any "please run this on $host" handoff), verify whether the current machine **is** that host. Cheapest possible check:

```
hostname -s
```

If the output matches the target, drop the ssh wrapper and run the command directly.

Rule: whenever a user message mentions a host by name (`pro`, `air`, `$service.home.local`, etc.), if the command you're about to issue depends on that host being remote, `hostname -s` check first. This check is also free to run as part of any "deploy this" or "restart the service on $host" workflow.

Origin: 2026-04-23 weave — ssh'd to a host the session already ran on.

## Never Chain Two `sudo` Calls in a `!` Block

When presenting a `!` command for the user to run, do NOT chain two separate `sudo` invocations with `&&`:

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

This does NOT apply to:

- A single `sudo` followed by non-sudo verification commands (`sudo X && verify_y` is fine, the verify inherits no password requirement)
- A single `sudo bash -c "..."` that internally chains multiple privileged operations (one password entry, one process)
- The "compose verify with fix" pattern from `~/.claude/rules/debugging.md` — which explicitly chains a fix with a verify, not two privileged operations

Origin: 2026-04-26 — chained `sudo ... && sudo ...` `!` block, second sudo silently skipped.

## SSH inside `while-read` Loop Drains Parent Stdin

`ssh` reads from stdin by default. When invoked inside a `while read VAR; do ...; done < <(jq ...)` (or any process-substitution-fed read loop), `ssh` consumes pending lines from the jq pipe **before the next iteration's `read` can see them** — the loop exits silently after the first iteration with no error message.

**Diagnosis signal**: a host loop that should iterate N hosts processes only the first one, exits 0, and emits no parse error. `bash -x` trace shows iteration 2's `read VAR` returning EOF immediately followed by post-loop code.

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

**Same trap applies to** any stdin-reading command in a process-substitution loop: `gpg`, `bash -s`, `read` itself, anything that defaults to reading stdin. When in doubt, redirect `< /dev/null` explicitly.

**Plan-time review checklist**: if your orchestrator-style script has `while read X; do ...; done < <(...)` AND the loop body invokes `ssh`/`gpg`/`bash -s`, check `-n` / `< /dev/null` is present BEFORE shipping. The trap is invisible to `shellcheck` and `bash -n` — it surfaces only at runtime, exactly once per affected host loop, and looks like a successful run with missing data.

Origin: 2026-05-06 PR #153 — bare ssh in jq-fed read loop dropped all hosts but the first.

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

**When to use which**:

- `ssh host 'cmd'` (single quotes) — fine for single-line commands without quotes inside
- `ssh host "pct exec X -- bash -s" <<'EOF' ... EOF` — required for any multi-line script with `()`, heredocs, function definitions, or any shell metacharacter
- `ssh host 'pct exec X -- bash -c "..."'` — only for trivial commands; ban for anything with metacharacters

**Detection while composing**: if the command body has any of `()`, `$()`, backticks, `*`, `!`, `<<`, or quotes nested >1 level deep, switch to the heredoc + `bash -s` form. The cost of switching is one extra line; the cost of debugging a layer-2 misinterpretation through three remote shells is several round-trips.

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

**Composition gate**: before writing any `bash -c '...'`, `ssh host '...'`, or `ssh host 'pct exec <vmid> -- bash -c/-s ...'`, scan the inner body for the metacharacter set `()`, `$()`, backticks, `*`, `!`, `<<`, nested quotes — **commentary parentheses in `echo` statements count** (e.g. `echo (already paused)`). Any hit → switch shape (single-quoted `bash -s` heredoc) before sending.

Origin: 2026-05-06 / 2026-05-11 / 2026-06-07 — `syntax error near unexpected token '('` from commentary parens in `echo === ... ===` headers through three remote shells; structural, recurs per metacharacter unless heredoc + `bash -s` is the default.

## Prefer sed/awk over `python3 -c` for inline filesystem edits

When the task is "edit one line of an INI/JSON/YAML file" or "remove a section header", default to `sed`/`awk` over `python3 -c "..."`. The Python form has two recurring failure modes that don't apply to sed:

1. **Multi-line `-c` payload is fragile in chat / prompt presentation**: when you present a multi-line `python3 -c "..."` block to the user, markdown wrapping / paste rendering frequently adds leading spaces to continuation lines. Python's significant indentation then surfaces as `IndentationError: unexpected indent` even though the source was syntactically valid before paste. sed/awk scripts are statement-per-line with no indentation semantics — wrap-resilient.

2. **`python3 -c` with shell-quoted multi-line is hard to compose verbatim**: avoiding shell-side escape collisions for `'...'` inside `"..."` for inside `;`-chained statements gets messy fast. sed/awk's regex-and-action grammar is one shell-quote layer deep.

**Concrete substitutions**:

| Task | python3 -c (avoid) | sed/awk (prefer) |
|---|---|---|
| Remove INI section `[name]` and its body | `python3 -c "import configparser; c=configparser.ConfigParser(); c.read('f'); c.remove_section('name') if 'name' in c else None; c.write(open('f','w'))"` | `sed -i.bak '/^\[name\]$/,/^\[/{/^\[name\]$/d; /^\[/!d}' f` |
| Replace value of `key = ...` in INI | `python3 -c "..."` (multi-line) | `sed -i 's/^key = .*/key = newvalue/' f` |
| Filter JSON one key | (Python possible) | `jq '.key' f` (preferred over either) |
| Edit YAML | (Python possible) | `yq` if available, else sed for simple cases |

**When python IS the right tool**: when the edit needs Python-grade parsing (multi-line JSON edit with comments, complex schema migration, anything where regex fragility outweighs paste fragility). In those cases, `python3 < /tmp/script.py` with the script written via Write first — never `python3 -c` inline.

Origin: 2026-05-11 — multi-line `python3 -c` paste-broke with `IndentationError`; one sed command worked first try.

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
