# Pre-PR Cookbook Implementation Checklist

Load before `gh pr create` on a cookbook change. Each check catches a recurring bug class observed in past sessions.

## The 5-check pass

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

3. **Bind-mount host UID matches cookbook owner**: every `directory ... owner` resource on a bind-mount path must match the host UID set in the host pre-bootstrap (typically `100000:100000` on PVE unprivileged LXC for in-container UID 0, or `runtime_uid + 100000` for in-container service UIDs). Cross-check with the PVE host's `chown` setup in `phase-3a-lxc-create.md` or equivalent. See `~/.claude/docs/pve-lxc-detail.md` "Unprivileged LXC Bind-Mount Host Ownership Mapping".

4. **UDP-receiving container has `network_mode: host`**: any docker-compose service that listens on UDP (syslog, statsd, DNS) MUST have `network_mode: host`. docker-proxy unreliably forwards UDP. Probe:
   ```
   git diff origin/main...HEAD -- '*docker-compose*.yml' | grep -B5 'udp\|syslog\|statsd' | grep -E 'network_mode|udp'
   ```
   See `~/.claude/rules/docker-compose.md` "UDP Listener Containers Require `network_mode: host`".

5. **Idempotency/guard parse logic verified against live data**: any shell parse (`sed` / `awk` / `grep` / `jq`) embedded in an idempotency guard or convergence check (`not_if` / `only_if` / `skip_if`, or a plain bash guard like `ensure_*_license()`) must be run against REAL live output from the system it parses — not a hand-crafted sample — before the PR ships. Probe:
   ```
   body=$(curl -sk -u elastic:$PW "$ES/_license"); type=$(printf '%s' "$body" | sed -n 's/.*"type" *: *"\([^"]*\)".*/\1/p'); echo "type=[$type]"
   ```
   A parser that silently mis-extracts a field either re-runs a mutation on every converge (false-negative idempotency) or permanently skips a required mutation (false-positive) — both look clean in the PR diff and only misbehave on the real target. Sibling failure mode: `~/.claude/rules/ruby.md` "Guard must be evaluatable under mitamae's actual runtime privilege" (guard can't even run, vs. this — guard runs but parses wrong).

Implementation-level, distinct from the design-level `~/.claude/rules/adversarial-review.md`. Adversarial caught architecture bugs (TLS SAN, IAM size, JWKS fetch loop); these 5 checks catch implementation bugs that surface only at apply time.

## Origin

2026-05-09 6 sequential fix PRs for bugs all 4 checks catch at PR time.
2026-07-11 `ensure_basic_license()` sed parse verified against the live ES `_license` response before PR #731 shipped — no bug this time, but no checklist item required it either (check 5 added).
