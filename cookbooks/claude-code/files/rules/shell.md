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
