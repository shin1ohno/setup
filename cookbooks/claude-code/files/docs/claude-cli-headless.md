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
