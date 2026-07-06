# Headless `claude` CLI (non-interactive `claude -p`)

Load when a cookbook or script invokes the `claude` CLI non-interactively — a daemon, CI job, systemd/launchd service, or any `claude -p` not driven by a human terminal. Two version/mode-specific behaviors bit two different components in one session; both recur on any headless deployment.

## Auth is `claude setup-token` → `CLAUDE_CODE_OAUTH_TOKEN`, NOT a stored login

`claude setup-token` mints a **long-lived** token for headless/automation use. It is consumed via the env var **`CLAUDE_CODE_OAUTH_TOKEN`** (or a file holding it), NOT stored as an interactive login. Consequences:

- **`claude auth status` reports `loggedIn:false`** even when the token is set correctly and `claude -p` works. So an auth-presence GATE must check the **token env/file** directly (`test -s <token-file>`), never `claude auth status`.
- **Exit-code trap**: `claude auth status` exits `1` when logged out — but piping it through `head` (`claude auth status | head`) swallows the non-zero exit (`head` returns 0), masking the failure inside an `&&` / `only_if` chain. Read `${PIPESTATUS[0]}`, or don't pipe.

Wire the token into a systemd unit as a second, optional EnvironmentFile so a missing token before `setup-token` doesn't hard-fail:

```
EnvironmentFile=/opt/<svc>/memory-v2.env
EnvironmentFile=-/opt/<svc>/keeper-claude.env   # CLAUDE_CODE_OAUTH_TOKEN, mode 600, leading '-' = optional
Environment=HOME=/root
Environment=CLAUDE_BIN=/root/.local/bin/claude
```

Gate timer/service activation on the token file existing, not on `claude auth status`.

## `--mcp-config "{}"` is rejected on claude >= 2.1

`claude -p … --strict-mcp-config --mcp-config "{}"` fails with `Invalid MCP configuration: mcpServers: expected record, received undefined` on claude >= 2.1. Use `--mcp-config '{"mcpServers": {}}'` (empty servers = no tools, the pure-inference contract). Verify `claude --version` before reusing an older example verbatim — capability claims are values, probe them.

## Do NOT copy `~/.claude/.credentials.json` between hosts

An interactive login's `~/.claude/.credentials.json` holds `accessToken` + `refreshToken` + `expiresAt`; the **refresh token rotates on use**, so two hosts sharing one copied file silently invalidate each other (whichever refreshes second gets logged out). The correct mechanism is an **independent `claude setup-token` (or login) per host** — same account, separate token pair, no rotation conflict. See the credential-sharing probe in `~/.claude/rules/debugging.md`.

Origin: 2026-07-04 memory-v2 keeper on CT119 — `setup-token` token surfaced `loggedIn:false`; a `| head` masked `auth status` exit 1; `--mcp-config "{}"` errored on claude 2.1.201; the plan's "copy subscription creds" was corrected to a separate `setup-token` after probing the token structure.

## Runner death detection — 3-layer self-defense

A scheduled/headless `claude -p` runner (a launchd/cron/systemd-timer loop) needs 3 layers of self-defense:

1. **Pre-launch auth probe + output validation** — a run whose session output is ONLY「Not logged in · Please run /login」is a *failed iteration*, not a completed one: do NOT advance the last-success timestamp, notify once, and exit (so the missed work re-runs when a human resumes interactively). With token auth, gate on the token file per the section above (`test -s <token-file>`), never `claude auth status`.
2. **Grep the session output for terminal errors** — `monthly spend limit` is unrecoverable (waits on the monthly reset / an admin), so create a DISABLED sentinel + notify once and stop the loop itself (restarting every cycle is pure waste). `Request timed out` / `Connection closed` are transient, so back off via a sentinel + timestamp (skip a few cycles, then auto-resume).
3. **Deterministic pre-gates (gh/jq probes) are fail-closed** — if a probe returns an empty string or an error, SKIP that cycle. A fail-open shape ("unknown, so let the LLM decide") is banned (measured: a fail-open gate wasted 35 of 51 launches on needless opus sessions). In bash, `[ -n "$x" ] && [ "$x" = "0" ]` is the classic fail-open — a probe failure falls through to the launch branch; write `[ "$x" = "0" ] || [ -z "$x" ]` so a failure falls to the skip branch. Pair fail-closed with a "notify once after N consecutive skips" so a permanently-broken probe does not silently skip forever.

Origin: 2026-07 zp-issue-loops audit — an 8-line「Not logged in」-only session counted as completed (a83e457b); the loop restarted every minute after hitting the spend limit (947df123); a fail-open gate wasted 35 of 51 launches on empty opus sessions. Supported by 14 sessions.

## Permission reality — probe at design time, re-probe each run (do not normalize the observed matrix)

1. **Design-time probe (once)**: before designing a headless mutation loop (one that unattended-issues push / pr create / merge / label / notify), read `permissions.disableBypassPermissionsMode` in `/Library/Application Support/ClaudeCode/managed-settings.json`. If it is `"disable"`, `--permission-mode bypassPermissions` is inert and the headless run executes in the default mode (`ask` = immediate block with no approver present). In that case, measure each mutating command the loop issues from a REAL headless `claude -p` run, one command at a time, before unattending it — success in an interactive session is not evidence (a human approval is transparently supplied). One e2e marker issue / one dry-run pass is the minimum-cost probe. A gated command's alternative can live in the runner shell OUTSIDE claude (the launchd/cron bash) — the runner is outside claude's permission system.
2. **The matcher is sensitive to the issued form (fairly durable harness behavior, but re-confirm)**: an allowlist `Bash(git status:*)`-style prefix matcher is a string prefix match and does NOT match `git -C /path status`. Because `git-commit.md` mandates the `git -C <absolute-path>` form, write the headless allowlist in the exact form the loop issues (with `git -C`). Gating of `$()` substitution / `&&` compounds / multiline `-m` is content-specific (some PASS, some go to approval) — do not assume blanket "compound = blocked" or "single = allowed"; probe the exact form you plan to issue.
3. **Write-probe the hand-off file**: some versions write-guard everything under `~/.claude/` in a non-bypass session (Write / heredoc / printf all denied, observed — but version-dependent; it has succeeded in other periods). Write-probe the hand-off file once at design time; if denied, place it under the repo's `.git/` or the scratchpad.
4. **A recorded PASS/DENY matrix is a snapshot**: on the same machine, a 2026-06 DENY ceiling (`gh api graphql` / `gh pr merge`) flipped to PASS by 2026-07-06. Keep the detailed matrix in project memory (e.g. zp-SHIN `zp-pr-attend-headless-perms`), update it per run, and do NOT freeze it into this doc. Never skip a satisfied merge gate because a prompt or memory says "blocked" — attempt first, observe the DENY, then escalate.
