---
globs: ["*.sh", "*.zsh", "*.bash"]
---

# Shell Script Guidelines

- Always quote variables: `"$var"` not `$var`
- Use `set -euo pipefail` at the top of bash scripts
- Consider POSIX compatibility when the script may run on different shells
- Use `$()` for command substitution, not backticks
- Prefer `[[ ]]` over `[ ]` in bash/zsh scripts

## Locality Check Before Assuming Remote

Before writing any command that assumes a target host is remote (ssh, scp, rsync over ssh, `gh api` to a remote server, any "please run this on $host" handoff), verify whether the current machine **is** that host. Cheapest possible check:

```
hostname -s
```

If the output matches the target, drop the ssh wrapper and run the command directly. The 2026-04-23 weave session lost one round-trip attempting `ssh pro.home.local` before realizing the Linux box the session was on literally **was** pro. `hostname -s` returning `pro` would have surfaced this in under a second.

Rule: whenever a user message mentions a host by name (`pro`, `air`, `$service.home.local`, etc.), if the command you're about to issue depends on that host being remote, `hostname -s` check first. This check is also free to run as part of any "deploy this" or "restart the service on $host" workflow.

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

This rule exists because the 2026-04-26 session presented `sudo dpkg-divert ... && sudo systemctl restart tailscaled && sleep 3 && tailscale status | head -3` as a single `!` block. The first sudo ran (visible), the second silently did not (chain terminated invisibly), and verification of `tailscaled` showed it had not been restarted in 4 days. One extra round-trip to ask the user to run the restart separately.

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

This rule exists because PR #153 (2026-05-06 auto-mitamae orchestrator) shipped a `while ... done < <(jq -c '.[]' hosts.json)` loop with bare `ssh` inside; the orchestrator's first cycle reported only `host="monitoring"` results and silently dropped `host="weave"` entirely. `bash -x` trace showed iteration 2 returning EOF before the loop body ran. Fixed by adding `-n` to the ssh invocation; verified with a re-run that produced both host metrics correctly.

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

This rule exists because the 2026-05-06 monitoring CT 111 bootstrap tried `ssh ... pct exec ... bash -c "echo === step 1.3: bin/setup (mitamae binary download) ==="` and failed with `bash: -c: line 12: syntax error near unexpected token '('`. Removing the parens worked but the trap is structural — the next session will hit it with a different metacharacter unless the heredoc + `bash -s` pattern is the default.
