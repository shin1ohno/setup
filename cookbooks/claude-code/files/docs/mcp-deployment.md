# MCP Deployment Conventions at mcp.ohno.be

Site-specific rules for adding a new OAuth-protected MCP service to
`https://mcp.ohno.be/`. Codifies the precedent established by the
`/memory/` and `/roon/` deployments so subsequent services do
not re-derive the conventions through trial and error.

## Client-facing URL pattern

Services here use one of two transports. The existing services
(`memory` / `roon`) use **legacy MCP SSE transport** (MCP
spec 2024-11-05); services added from 2026-07 onward (`es-memory` and
later) use **streamable HTTP** — for those, see the FastMCP section
below, and note the `/sse` URL pattern in this section applies to the
legacy SSE services only.

A legacy SSE service exposes a `GET /sse` endpoint that opens an event
stream and a `POST /messages/` endpoint that delivers JSON-RPC client
messages. The URL to register in Claude.ai (or any MCP client) is
always:

```
https://mcp.ohno.be/<service>/sse
```

**Not** the bare base URL `https://mcp.ohno.be/<service>/`. Claude.ai's
MCP connector hits the registered URL verbatim with `GET`; without the
`/sse` suffix the request lands on the path the SSE server has not bound,
the connection idles ~10 seconds, and Claude reports a generic
authorization failure.

When a deployment is functionally complete (auth + container running +
`curl -i /<service>/sse` returns 401 with `WWW-Authenticate`), the
**finishing step** for the user is a single line stating the exact URL to
paste into Claude.ai. Do not sign off on the deployment with "the service
is running at /<service>/" — surface the `/sse` suffix explicitly.

## FastMCP streamable-HTTP: two claude.ai connector gotchas

When a service uses FastMCP over **streamable HTTP** (rather than legacy
SSE), two failure modes block registration as a claude.ai remote
connector. Both surface with healthy-looking startup logs, so neither is
visible without the checks below.

1. **Do not use `stateless_http=True`.** A stateless FastMCP server never
   issues the `Mcp-Session-Id` response header, and connector
   registration fails with `Your account was authorized, but no MCP
   server was found at the provided URL`. Stateful streamable HTTP with a
   **single uvicorn worker** is required. Pre-cutover check — confirm the
   header is present:

   ```
   curl -si -X POST <url> \
     -H 'Content-Type: application/json' \
     -H 'Accept: application/json, text/event-stream' \
     -d '<initialize request>' | grep -i mcp-session-id
   ```

2. **Mounting multiple FastMCP apps in one process** (Starlette `Mount`)
   requires the parent Starlette `lifespan` to start each sub-app's
   `session_manager.run()`, nested with `async with`. Omit it and startup
   logs stay clean while every request returns 500 `session manager not
   initialized`.

Origin: 2026-07-02 es-memory cutover #1 — shipped `stateless_http`, no
`Mcp-Session-Id` header, gateway reverted within minutes; PR #613 made it
stateful.

## ALLOWED_EMAILS expansion is a manual SSM put

The consent app reads its allow-list from
`/hydra/allowed-emails` in SSM Parameter Store. Adding a new email is a
user-run command (intentionally outside Claude's automatic-edit path —
the harness blocks it as a security perimeter change):

```
! AWS_PROFILE=sh1admn aws ssm put-parameter \
    --name /hydra/allowed-emails \
    --value "<existing>,<new>" \
    --type SecureString --overwrite \
    --region ap-northeast-1 --query Version --output text
```

After the put, regenerate the consent `.env` on the consent LXC (CT 110 —
the docker-hydra era `cookbooks/hydra/files/generate_env.sh` is gone; the
`lxc-consent` cookbook now generates `.env` itself, gated by a
`skip_if File.exist?` guard, so deleting the file forces regeneration on
the next apply):

```
ssh root@pve 'pct exec 110 -- bash -c "rm /root/deploy/consent/.env && cd /root/setup && ./bin/mitamae local pve/lxc-consent.rb"'
```

(Or just `rm` the file and let the auto-mitamae orchestrator's next cycle
regenerate it — the `remote_file` notify restarts the consent container
when the content changes.) Only the SSM put itself requires a `!` block.

## Token audience must be unverified (for now)

Hydra issues access tokens **without** an `aud` claim unless the client
passes RFC 8707 `resource=...`. Anthropic's Claude.ai connector does
not, so MCP servers behind this gateway must skip audience verification
in token validation:

- Python (es-memory auth-proxy precedent): `jwt.decode(...,
  options={"verify_aud": False})`
- Rust (rmcp auth via `jsonwebtoken`): `validation.validate_aud =
  false;`

Issuer + RS256 signature verification + the consent-screen ALLOWED_EMAILS
gate is the effective authorization perimeter for single-user setups.
Document this in the service's auth module so future readers know the
omission is intentional, not an oversight.

## Cookbook host gating uses the local Roon Core port, not IP

`pro_1` / `pro_2` / `pro_3` in `home-monitor/devices.tf` may resolve to
different NICs on the same physical machine; `pro_1`'s NIC can be down
while the machine itself is up answering on `pro_2` / `pro_3` IPs. Never
gate a cookbook on an exact IP match — gate on a *functional* check:

```ruby
# Wrong — fails when pro_1 NIC is down even though the host is up
current_ip = run_command("hostname -I", error: false).stdout.split.first
return unless current_ip == "192.168.1.20"

# Right — runs only on the host that actually has Roon Core listening
roon_core_listening = run_command(
  "ss -tln | grep -q ':9330\\b'", error: false
).exit_status == 0
return unless roon_core_listening
```

Apply the same pattern for any MCP service that depends on a colocated
backend (OpenMemory port, es-memory port, etc.) — gate on the colocated
service's listening port, not on the device map's expected IP.

## nginx upstream resilience

The `home-monitor/devices.tf` derived `<service>_upstream_servers` lists
should fan out across all `pro_*` devices, not pin to one. Listing all
three IPs gives nginx automatic failover if a NIC flips and matches the
existing pattern for `mcp_upstream_servers`, `memory_upstream_servers`,
etc. The container itself runs on a single host (network_mode: host); the
fan-out is purely a network-availability hedge.

## Container UID and the `/root/...` mount trap

If a service's docker-compose mounts host config under
`/root/.config/<svc>/...` and runs the container as a non-root UID, the
container user cannot traverse `/root` (mode 700, owned by root in the
image). Either:

- Drop `user: "${UID}:${GID}"` and let the container run as root (simplest
  for single-user systems; the host bind is owned 1000 but root-in-container
  has full access), or
- Set `XDG_CONFIG_HOME=/data` in the container, mount the host config at
  `/data/<svc>/`, and keep the user override.

The cookbook should pre-create the host config file (touch with the
expected mode) so the bind mount does not silently turn into a directory
on first start. This rule exists because the 2026-04-28 roon-mcp deploy
spent a debugging round on a hung `client.connect()` whose root cause was
`Permission denied` reading `/root/.config/roon-rs/tokens.json` from inside
the container.
