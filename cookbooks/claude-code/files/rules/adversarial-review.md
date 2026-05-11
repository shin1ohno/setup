# Adversarial Plan Review

Load when a plan involves any security-sensitive component. Launch an adversarial review sub-agent BEFORE implementation — required, not optional.

## Triggers

- OAuth / OIDC flows (DCR, consent, token issuance / validation, JWKS)
- JWT validation, audience / issuer / scope checks
- Secret mounts (tokens.json, ssh keys, TLS certs) with bind-mount path / UID semantics
- nginx `auth_request` or other reverse-proxy access gates
- Privilege boundaries between cooperating services (auth-proxy → MCP server, edge agent → home server)
- ALLOWED_EMAILS / IP allow-lists / firewall rules

## Prompt template for the review agent

> Review this plan as an adversary. For each component, identify:
> 1. Authentication bypasses or token leaks
> 2. Privilege escalation paths
> 3. Environment assumptions that break in production (IP addresses, NIC configurations, path assumptions, container user mappings)
> 4. Configuration mismatches between layers (nginx ↔ docker-compose ↔ application)
> Number each concern and assign severity (blocker / risk / non-issue).

Distinct from the post-implementation `code-reviewer` plugin — this catches **design-level** problems while redesign costs minutes, not sessions.

## Origin

2026-04-28 roon-mcp OAuth session surfaced 10 pre-implementation concerns (JWKS fetch loop, audience claim mismatch, IP gate vs dual-NIC reality, token mount rw + UID) that collectively would have cost 3-5 debugging sessions to discover post-implementation.
