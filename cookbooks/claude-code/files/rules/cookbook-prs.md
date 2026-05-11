# Pre-PR Cookbook Implementation Checklist

Load before `gh pr create` on a cookbook change. Each check catches a recurring bug class observed in past sessions.

## The 4-check pass

1. **IP literal vs `contracts/devices.json`**: every IP literal in the diff must match a `contracts/devices.json` entry. Probe:
   ```
   git diff origin/main...HEAD | grep -oE '192\.168\.[0-9]+\.[0-9]+' | sort -u
   jq -r '.devices | to_entries[] | "\(.value.lxc.ip // .value.tailscale.ip // "?")"' ~/ManagedProjects/home-monitor/contracts/devices.json | sort -u
   ```
   Any IP in the diff not in devices.json is a hardcoded fabrication — fix or document. See `~/.claude/rules/ruby.md` "IP literal must come from contracts/devices.json".

2. **Healthcheck command unquoted shell variables**: every `healthcheck.test` in docker-compose.yml in the diff must single-quote any `${VAR}` substituted from `.env`. Probe:
   ```
   git diff origin/main...HEAD -- '*docker-compose*.yml' | grep -A2 'test:.*\${'
   ```
   Unquoted `${PASSWORD}` with metacharacters → `bash: syntax error near unexpected token (`, container marks `unhealthy` even when service is functional.

3. **Bind-mount host UID matches cookbook owner**: every `directory ... owner` resource on a bind-mount path must match the host UID set in the host pre-bootstrap (typically `100000:100000` on PVE unprivileged LXC for in-container UID 0, or `runtime_uid + 100000` for in-container service UIDs). Cross-check with the PVE host's `chown` setup in `phase-3a-lxc-create.md` or equivalent. See `~/.claude/rules/pve-lxc.md` "Unprivileged LXC Bind-Mount Host Ownership Mapping".

4. **UDP-receiving container has `network_mode: host`**: any docker-compose service that listens on UDP (syslog, statsd, DNS) MUST have `network_mode: host`. docker-proxy unreliably forwards UDP. Probe:
   ```
   git diff origin/main...HEAD -- '*docker-compose*.yml' | grep -B5 'udp\|syslog\|statsd' | grep -E 'network_mode|udp'
   ```
   See `~/.claude/rules/docker-compose.md` "UDP Listener Containers Require `network_mode: host`".

Implementation-level, distinct from the design-level `~/.claude/rules/adversarial-review.md`. Adversarial caught architecture bugs (TLS SAN, IAM size, JWKS fetch loop); these 4 checks catch implementation bugs that surface only at apply time.

## Origin

2026-05-09 ADR-0005 Phase 3b session shipped 6 fix PRs sequentially for bugs all 4 of these checks would have caught at PR time, costing ~3 hours of fix-PR-CI-merge-redeploy cycles.
