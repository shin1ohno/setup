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
