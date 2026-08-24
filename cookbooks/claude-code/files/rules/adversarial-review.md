# Adversarial Plan Review

Load when a plan involves any security-sensitive component. Launch an adversarial review sub-agent BEFORE implementation — required, not optional.

## Triggers

- OAuth / OIDC flows (DCR, consent, token issuance / validation, JWKS)
- JWT validation, audience / issuer / scope checks
- Secret mounts (tokens.json, ssh keys, TLS certs) with bind-mount path / UID semantics
- nginx `auth_request` or other reverse-proxy access gates
- Privilege boundaries between cooperating services (auth-proxy → MCP server, edge agent → home server)
- ALLOWED_EMAILS / IP allow-lists / firewall rules
- Transport-rewrite rules whose scope decides WHICH credential is used — git `insteadOf` / `pushInsteadOf`, ssh_config `Match`/`Host` blocks, proxy `no_proxy`. A rewrite that is correct today can silently reroute traffic onto the wrong identity as the host's credential set changes later, so review the scope against every credential the host may acquire, not just the ones it has
- Provisioning a credential onto a host that did not previously have one — adding a key can ACTIVATE dormant conditional logic elsewhere in the config
- An unattended runner combining `--permission-mode bypassPermissions` with a `--disallowedTools`/`--allowedTools` clamp — the clamp's runtime effectiveness is a claim to VERIFY, not a property of the flag list. Review must enumerate equivalent capabilities left reachable (a CLI on PATH duplicating a denied MCP server, subagent inheritance, alternate tool names) and require the Live Tool-Clamp Gate (detail doc) before ship

Detail (prompt template / Live Token Round-Trip Gate / origins): see `~/.claude/docs/adversarial-review-detail.md`.
