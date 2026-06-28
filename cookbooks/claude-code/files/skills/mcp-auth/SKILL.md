---
name: mcp-auth
description: >-
  Check the connection and authentication status of every MCP server and
  re-authenticate any that need it, one at a time. Use when the SessionStart
  MCP health hook reports "NEEDS-AUTH" / "MCP connectors need attention", when
  an mcp__* tool call fails with an auth or connection error, or when the user
  asks to check MCP status, reconnect MCP, "MCP 認証", "check mcp",
  "mcp 繋がってない", "認証されていない MCP を認証して".
---

# mcp-auth — MCP connection & auth checker / re-authenticator

Goal: report every MCP server's health, then re-authenticate the ones that need
it, sequentially. OAuth login is interactive (browser + `localhost` callback),
so you drive `claude mcp login` and surface the URL — the user completes the
browser step.

## 1. Enumerate every MCP server (two sources)

1. **Session tool registry — ground truth for what is loaded.** Group the MCP
   tools available to you in this session by their `mcp__<server>__` prefix.
   This is the only source that sees connectors absent from `claude mcp list`
   (notably **notion**, which surfaces only as `mcp__notion__authenticate` /
   `mcp__notion__complete_authentication`).
2. **`claude mcp list` — health + URL for OAuth connectors.** Run
   `timeout 12 claude mcp list`. Classify each line by its **text label, not
   the ✔/✓ glyph** (STATUS = the text after the last ` - `):
   - `Needs authentication` → **NEEDS-AUTH**
   - `Pending approval` → **PENDING**
   - `tools fetch failed` → **DEGRADED** (up; no login)
   - `Connected` → **CONNECTED**
   - `Failed to connect` / `Connection error` → **DOWN**

Match names case-insensitively (casing drifts: `Cognee`/`cognee`,
`memory`/`ai_memory`). `claude mcp get` / `claude mcp login` need the **exact
name as printed**, including any `claude.ai ` prefix.

Present a short status table to the user before acting.

## 2. Re-authenticate, one server at a time (sequential — never parallel)

### OAuth connectors (cognee, roon, ai memory, Structured — the ones in `claude mcp list`)

1. Run `claude mcp login "<exact name>"` **in the background**
   (`run_in_background: true`) so the callback wait does not hang the turn.
2. Read the command's stdout and surface the OAuth URL verbatim to the user
   ("Open this to authenticate: <url>"). On a desktop host it may auto-open the
   browser.
3. Poll `claude mcp get "<exact name>"` (or `claude mcp list`) every ~5s, up to
   ~120s, until it shows `Connected`. Report success, then move to the next
   server. If it never connects, report the failure and stop auto-driving that
   one — do **not** loop forever.

### notion (NOT a `claude mcp login` connector)

1. Call the `mcp__notion__authenticate` tool; surface the returned URL.
2. After the user authenticates, call `mcp__notion__complete_authentication`.
3. Confirm a notion tool now works.

### PENDING (Pending approval)

Tell the user to run `/mcp` and approve the server — this is project approval,
not OAuth login. Do **not** run `claude mcp login`.

### DOWN (transient)

Report as a transient connection failure. Optionally probe the URL once
(`curl -s -o /dev/null -w '%{http_code}' -I <url>`); only treat it as NEEDS-AUTH
(and run login) if it returns 401/403. Otherwise suggest a retry.

## Guardrails

- Re-authenticate sequentially — each login opens its own browser flow.
- Only **NEEDS-AUTH** (or DOWN confirmed 401/403) triggers `claude mcp login`.
- Some Anthropic-hosted connectors support auth only via claude.ai connector
  settings, not local OAuth. If `claude mcp login` reports it cannot, point the
  user to claude.ai settings instead of retrying.
- notion's enablement is per-project (`disabledMcpServers` in `~/.claude.json`).
  If notion is disabled in the current project, do not flag it as broken.
- This skill changes **auth state only** — it never edits MCP server configs or
  any cookbook file.
