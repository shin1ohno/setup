# Adversarial Plan Review — Prompt Template, Live-Token Gate & Origins

Load when a plan involves any security-sensitive component. On-demand detail for `~/.claude/rules/adversarial-review.md` — read this when launching the review sub-agent or enforcing a JWT claim check.

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

Origin: 2026-06-07 synthetic-token audit missed real `aud=[]`; live probe caught it.

## Origin

2026-04-28 roon-mcp OAuth review surfaced 10 pre-implementation concerns worth 3-5 debugging sessions.
