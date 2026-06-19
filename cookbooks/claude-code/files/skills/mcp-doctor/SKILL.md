---
name: mcp-doctor
description: Diagnose and repair MCP server connection/auth problems — local Docker MCP servers (cognee-local, memory-local) and the hosted socrates server. Use when MCP tools fail, a server shows ECONNRESET / "failed to reconnect", "MCPが繋がらない", cognee/mem0/socrates is unreachable, or the session-start health hook reports a fault. Handles the Docker Desktop port-forward wedge (all published ports refuse despite LISTEN) with a bounded auto-restart ladder.
user-invocable: true
allowed-tools: ["Bash", "mcp__socrates__auth_status", "mcp__socrates__connect_looker"]
---

# MCP Doctor

## Purpose

Restore MCP connectivity without a human walking the diagnostic tree. Covers the
recurring **Docker Desktop (Mac) port-forward wedge**: every published port is
refused from the host (`curl` → `connect after 0 ms` / http_code `000`) even
though `lsof` shows `com.docker.backend` holding the socket `LISTEN` and the
containers are internally healthy. Container restart does NOT fix this layer — a
full Docker Desktop restart does.

## Scope (targets)

Read the live set from `~/.claude.json` `mcpServers` (do not hardcode):

| MCP | typical endpoint | class | fixable here |
|-----|------------------|-------|--------------|
| `cognee-local` | `http://127.0.0.1:8002/mcp` | local Docker | yes — Docker ladder |
| `memory-local` | `http://127.0.0.1:8765/mcp` | local Docker (openmemory) | yes — Docker ladder |
| `socrates` | `https://…run.app/mcp` | hosted (Mercari) | reachability only; auth = guide re-auth |

Compose project lives at `~/deploy/local-mcp/` (named volumes — `docker compose down`
keeps data; **NEVER `down -v`**).

## Modes

- **AUTO** (summoned by the session-start hook, or user says "自動で直して"): execute
  the ladder without asking, honoring the safety rails below. The user has
  pre-approved a Docker Desktop restart.
- **MANUAL** (user runs `/mcp-doctor` to inspect): report state; apply the
  destructive step (Docker Desktop restart) only after confirming with the user.

## Workflow

### 1. Inventory + probe
- `jq -r '.mcpServers | to_entries[] | "\(.key) \(.value.url)"' ~/.claude.json` —
  list configured servers. Local = `http://127.0.0.1:<port>/`.
- Probe each local endpoint from the host:
  `curl -sS -m4 -o /dev/null -w "%{http_code}" http://127.0.0.1:<port>/mcp`
  - non-000 → connection OK (live server). `000` → connection refused.
- For socrates: call `mcp__socrates__auth_status` (this is the only way to learn
  Looker auth state — a shell cannot).

### 2. Local Docker ladder (only if a local endpoint is `000`)
Walk in order; re-probe after each step; stop as soon as the endpoint answers.

1. **Daemon down?** `docker info` fails → Docker Desktop isn't running →
   `open -a "Docker Desktop"`, poll `docker info` until up.
2. **Container missing / Exited?** `docker compose -f ~/deploy/local-mcp/docker-compose.yml ps`
   → if the target service is not `Up`, `docker compose -f … up -d` (do NOT
   restart all of Docker for this). Re-probe.
3. **Wedge confirmed?** Container `Up` and internally healthy
   (`docker exec <c> python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/mcp')"`
   → expect `406` HTTPError = serving), `lsof -nP -iTCP:<port>` shows `LISTEN`,
   **but the host probe is `000` on multiple published ports** →
   **Docker Desktop restart**:
   - `osascript -e 'quit app "Docker Desktop"'`; wait until the process is gone.
   - `open -a "Docker Desktop"`; poll `docker info` until up. Expect one transient
     first-boot self-restart (daemon comes up, socket briefly disappears, app
     relaunches itself ~once) — relaunch if the process vanishes.
   - Containers are `unless-stopped` → they auto-return. cognee-mcp gates on
     cognee `depends_on: healthy`, so 8002 returns 200 ~15–20 s after the others.
   - Record the sentinel: `mkdir -p ~/.claude/state && touch ~/.claude/state/mcp-doctor-last-restart`.

### 3. socrates auth
- If `auth_status` shows Looker disconnected/expired, do NOT auto-restart anything
  (OAuth/browser flow). Offer `mcp__socrates__connect_looker` and tell the user
  to complete the browser grant. (BigQuery `payment_outer` read needs the
  separate Chrome 16h grant — note it if relevant.)

### 4. Verify (state evidence, not "looks fixed")
- Local: `POST` an MCP initialize and require `200`:
  `curl -sS -m6 -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:<port>/mcp -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"doctor","version":"0"}}}'`
  — expect `200` (cognee returns `serverInfo {"name":"Cognee",…}`).
- socrates: `auth_status` reports connected.
- Tell the user to run `/mcp` to reconnect the Claude Code client once the
  servers answer.

## Safety rails (mandatory in AUTO mode)

- **Cold-start guard**: a published port refusing while its container has been
  `Up` < 60 s is normal boot — wait/re-probe, do NOT restart Docker.
- **Wedge confirmation**: only restart Docker Desktop when the container is
  `Up` > 60 s AND **multiple** published ports refuse from the host. A single
  refusing port = container-specific or cold start → use step 2, not step 3.
- **Cooldown**: if `~/.claude/state/mcp-doctor-last-restart` was modified within
  the last 10 min (`find ~/.claude/state/mcp-doctor-last-restart -mmin -10`), do
  NOT restart Docker Desktop again — report and let it settle.
- **Bounded loop**: at most **2** Docker Desktop restarts per invocation. If the
  endpoint still fails after the 2nd, STOP and report (check
  `docker logs local-mcp-cognee-mcp-1 --tail 40` for an internal fault, e.g. OOM
  or a crash-loop unrelated to the forward layer).
- **Sandbox**: `osascript` (GUI control) and `ps`/`pgrep` (process listing) are
  blocked in the default Bash sandbox on this host (`Connection Invalid …
  hiservices-xpcservice`, `sysmond service not found`). Run those Bash calls with
  `dangerouslyDisableSandbox: true`.

## Report format

| MCP | host probe | internal | action taken | result |
|-----|-----------|----------|--------------|--------|
| cognee-local | 000 → 200 | healthy | Docker Desktop restart | recovered |
| memory-local | 200 | — | none | ok |
| socrates | reachable | auth: connected | none | ok |

If nothing was wrong: "All MCP servers healthy (cognee-local, memory-local, socrates)."
Background: zp-SHIN memory `docker-desktop-portforward-wedge.md`.
