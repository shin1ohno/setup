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
> 5. JWT claim validation added or tightened: decode a REAL token from the actual live issuer and confirm every required claim is present with the expected value. Mark a blocker if no live-token sample was obtained — synthetic tokens cannot confirm this.
> Number each concern and assign severity (blocker / risk / non-issue).

Distinct from the post-implementation `code-reviewer` plugin — this catches **design-level** problems while redesign costs minutes, not sessions.

## Live Token Round-Trip Gate (JWT claim enforcement)

Before merging any change that ADDS or TIGHTENS a JWT claim check (audience, issuer, scope, custom claim) on a gate fronting a running system, decode a REAL token minted by the actual live issuer and confirm the proposed check PASSES for its actual claim values. Source-level adversarial review with synthetic tokens is necessary but NOT sufficient — a synthetic token encodes your assumption about the claim shape, which is exactly what's in question.

- If the real token has `aud=[]` (empty) and the validator requires a non-empty audience, the validator is WRONG — regardless of what `.well-known/oauth-protected-resource` advertises as the resource. The advertised resource indicator is what a spec-compliant client *should* request; it is not proof of what the issuer actually mints.
- Capture the real claim by adding decode-only LOGGING (no enforcement) to the gate, triggering one real client request, reading the logged claim, THEN enforcing the observed value. Never enforce-first.

Origin: 2026-06-07 setup security audit. The H2 fix enforced `audience=https://mcp.ohno.be/cognee` and PASSed source-level adversarial verification with synthetic PyJWT tokens. A pre-merge live probe revealed the real claude.ai token carries `aud=[]` — enforcing ANY audience value would have 401'd every real token and taken down cognee/memory MCP. PR #438 held the fix instead.

## Origin

2026-04-28 roon-mcp OAuth session surfaced 10 pre-implementation concerns (JWKS fetch loop, audience claim mismatch, IP gate vs dual-NIC reality, token mount rw + UID) that collectively would have cost 3-5 debugging sessions to discover post-implementation.
