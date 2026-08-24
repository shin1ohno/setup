# Adversarial Plan Review — Prompt Template, Live-Token Gate & Origins

Load when a plan involves any security-sensitive component. On-demand detail for `~/.claude/rules/adversarial-review.md` — read this when launching the review sub-agent or enforcing a JWT claim check.

## Prompt template for the review agent

> Review this plan as an adversary. For each component, identify:
> 1. Authentication bypasses or token leaks
> 2. Privilege escalation paths
> 3. Environment assumptions that break in production (IP addresses, NIC configurations, path assumptions, container user mappings)
> 4. Configuration mismatches between layers (nginx ↔ docker-compose ↔ application)
> 5. JWT claim validation added or tightened: decode a REAL token from the actual live issuer and confirm every required claim is present with the expected value. Mark a blocker if no live-token sample was obtained — synthetic tokens cannot confirm this.
> 6. Tool-restriction clamps on unattended runners (`--disallowedTools`/`--allowedTools` under `bypassPermissions`): does the declared list actually block the CAPABILITY at runtime, including equivalent paths — a CLI reachable via Bash that duplicates a denied MCP server, subagent/workflow inheritance of the deny, alternate tool names? Mark a blocker unless verified by a live probe (Live Tool-Clamp Gate below).
> Number each concern and assign severity (blocker / risk / non-issue).

Distinct from the post-implementation `code-reviewer` plugin — this catches **design-level** problems while redesign costs minutes, not sessions.

## Live Token Round-Trip Gate (JWT claim enforcement)

Before merging any change that ADDS or TIGHTENS a JWT claim check (audience, issuer, scope, custom claim) on a gate fronting a running system, decode a REAL token minted by the actual live issuer and confirm the proposed check PASSES for its actual claim values. Source-level adversarial review with synthetic tokens is necessary but NOT sufficient — a synthetic token encodes your assumption about the claim shape, which is exactly what's in question.

- If the real token has `aud=[]` (empty) and the validator requires a non-empty audience, the validator is WRONG — regardless of what `.well-known/oauth-protected-resource` advertises as the resource. The advertised resource indicator is what a spec-compliant client *should* request; it is not proof of what the issuer actually mints.
- Capture the real claim by adding decode-only LOGGING (no enforcement) to the gate, triggering one real client request, reading the logged claim, THEN enforcing the observed value. Never enforce-first.

Origin: 2026-06-07 synthetic-token audit missed real `aud=[]`; live probe caught it.

## Live Tool-Clamp Gate (bypassPermissions runners)

Same shape as the Live Token gate, applied to `--disallowedTools`/`--allowedTools` clamps on unattended `claude -p` runners: the flag list is your assumption about what is blocked, which is exactly what's in question. Before shipping the clamp:

1. **Probe the deny mechanics with one real headless run** — (a) a denied built-in (e.g. `Bash`) is actually refused, (b) a bare `mcp__<server>` prefix removes the WHOLE server's tools (they become unregistered — ToolSearch finds nothing), (c) the deny PROPAGATES into subagents/workflow fan-out. All three confirmed on claude 2.1.241 (2026-08-23, sh1-cloud) — but re-probe per host/version; this is harness behavior, not a spec.
2. **Enumerate CLI equivalents of every denied MCP server** — denying `mcp__…_Gmail` while `Bash` stays allowed leaves `gws gmail send` reachable; the same holds for `gh`/`gcloud`/`ncli`/`curl` vs their MCP counterparts, each carrying the host's ambient credentials. A clamp that blocks only the MCP half of a capability is decorative.
3. **Deny-lists rot**: every new connector registered on the host after ship widens the reachable set. Note a revisit trigger ("re-audit on new connector") in the runner's cookbook.

Origin: 2026-08-23 handoff-worker security review C1 — the first-cut clamp denied 25 MCP entries but left `Bash` open, so `gws`/`gh` (scope `repo`)/`gcloud` (operator account)/`curl` bypassed every deny; the live 3-point probe then confirmed the corrected clamp holds, subagents included.

## Origin

2026-04-28 roon-mcp OAuth review surfaced 10 pre-implementation concerns worth 3-5 debugging sessions.
