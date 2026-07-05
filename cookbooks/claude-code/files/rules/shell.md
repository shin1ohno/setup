---
globs: ["*.sh", "*.zsh", "*.bash"]
---

# Shell Script Guidelines

This file is the always-loaded summary. Long examples + origin notes are in `~/.claude/docs/shell-detail.md` (NOT auto-imported — load on demand via Read tool when a section pointer matches the current task).

## Locality Check Before Assuming Remote

Before writing any command that assumes a target host is remote (ssh, scp, rsync over ssh, `gh api` to a remote server, any "please run this on $host" handoff), verify whether the current machine **is** that host. Cheapest possible check:

```
hostname -s
```

If the output matches the target, drop the ssh wrapper and run the command directly.

Rule: whenever a user message mentions a host by name (`pro`, `air`, `$service.home.local`, etc.), if the command you're about to issue depends on that host being remote, `hostname -s` check first. This check is also free to run as part of any "deploy this" or "restart the service on $host" workflow.

Origin: 2026-04-23 weave — ssh'd to a host the session already ran on.

## SSH Reachability Probe Before Delegating or Claiming "No Key"

Trigger: you are about to (a) frame a step as "please run this on <host>" / present `! ssh/scp ...`, (b) claim "no key for <host>" / "this shell cannot reach <host>", or (c) design a flow around <host> being unreachable.

1. **Resolve what plain ssh would actually do — zero network, 1 second**:
   ```bash
   ssh -G <host> | grep -iE '^(hostname|user|identityfile) '  # effective config incl. ~/.ssh/config aliases
   ssh-keygen -F <host>                                        # known_hosts registration (first-contact check)
   ```
   `ssh -G` shows the IdentityFile plain ssh will use; it supersedes guessing from `ls ~/.ssh`.

2. **Probe once**, letting the user's config + agent work, with hang guards only:
   ```bash
   ssh -o ConnectTimeout=5 <host> hostname
   ```
   Add `-o StrictHostKeyChecking=accept-new` for a first-contact host. A failed `-o BatchMode=yes` run with hand-enumerated `-i` keys proves "these keys failed" — NEVER "no credential exists". Do not claim "鍵がない" from it.

3. **`Too many authentication failures`** (server disconnects mid-auth) = the agent/config offered too many keys, not a missing key. Retry once with `-o IdentitiesOnly=yes -i ~/.ssh/<host>_ed25519` (key path from step 1).

4. **Write ssh options as literal argv tokens.** `KEY="-i ~/.ssh/x"; ssh $KEY host` makes ssh parse the whole string as one token (`hostname contains invalid characters`). Never pack option+path into one shell variable.

5. **Probe failed → report the exact error class** (auth vs network vs host-key), record the host reachability map to project memory (cf. `session-shell-ssh-access`), and present the fallback as ONE composed `! ssh/scp ...` command — not a sequence of retries for the user.

Origin: 2026-07-04 ×2 — three delegations + a "鍵がない" claim the user disproved with plain ssh/scp; a separate session's 5 ssh attempts (incl. Too-many-auth-failures + the `-i`-in-variable token bug) all compressible to one step-1+2 probe.

## Bash Tool Runs in the User's Login zsh (darwin) — bash/Linux idiom traps

The Claude Code Bash tool executes through the user's **login zsh** on darwin, not bash. bash/Linux one-liners that look correct fail in zsh-specific ways that are invisible to `bash -n` and usually surface as a *silent* wrong result, not an error. Five recurring traps:

1. **Unquoted `$var` is NOT word-split.** `for r in $REGIONS; do …` iterates ONCE over the whole string — zsh does not field-split unquoted parameters (the opposite of bash). Enumerate elements literally, use an array, or wrap the loop in `/bin/bash -c '…'`.
2. **Unmatched glob aborts the whole script.** zsh `nomatch` makes an unmatched `*.foo` a hard error that kills a multi-line script mid-run — earlier loop output is discarded with it. Quote globs you don't want expanded, or run under bash.
3. **zsh builtins shadow `/usr/bin` commands.** `log …` hits the zsh `log` builtin (`too many arguments`), not `/usr/bin/log`. Verify with `type <cmd>`; call the full path (`/usr/bin/log show …`) when a builtin shadows the binary you meant.
4. **A broken `.zshrc` compdef makes `aws` silently exit 1** (git/gh/curl unaffected). Wrap `aws` in `/bin/bash -c '…'` — see memory `aws-cli-needs-bash-c-wrapper`.
5. **History expansion mangles `!`** (e.g. `!=` inside an interactive jq filter) — see the `zsh History Expansion Mangles !=` section below.

**Default policy**: write any command containing a loop, a glob, or multi-line structure as `/bin/bash -c '…'` or `bash -s <<'EOF' … EOF` from the start. Observing ONE zsh-dialect error is the signal to switch the whole command to bash — do not patch it token by token.

**Verification discipline**: before reporting "0 results", drop `2>/dev/null` and re-run one representative case bare to confirm no zsh error was hidden (general form: `~/.claude/rules/debugging.md` Silent Failure Detection). A command that succeeds once but fails inside a loop → suspect the word-split trap (#1) before any external cause. Inline diagnostic one-liners are also subject to the macOS external-command audit (`timeout` / `flock` → exit 127; see below), not just cookbook-distributed scripts.

Origin: 2026-07-04 — `$REGIONS` / `$repos` word-split misdiagnosed as throttling / reported a false "0"; `log` builtin `too many arguments`; `timeout` exit 127.

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

Detail: see `~/.claude/docs/shell-detail.md#awk-bwk-vs-gawk`.

## macOS External-Command Audit for Ported Linux Scripts

Detail: see `~/.claude/docs/shell-detail.md#macos-external-command-audit`.

## zsh History Expansion Mangles `!=` in Interactive jq — Avoid `!` in tested filters

Detail: see `~/.claude/docs/shell-detail.md#zsh-bang-history-expansion`.
