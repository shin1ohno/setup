# Pre-PR Cookbook Implementation Checklist

Load before `gh pr create` on a cookbook change. Each check catches a recurring bug class observed in past sessions.

## The 7-check pass

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
   See `~/.claude/docs/docker-compose.md` "UDP Listener Containers Require `network_mode: host`".

5. **Idempotency/guard parse logic verified against live data**: any shell parse (`sed` / `awk` / `grep` / `jq`) embedded in an idempotency guard or convergence check (`not_if` / `only_if` / `skip_if`, or a plain bash guard like `ensure_*_license()`) must be run against REAL live output from the system it parses — not a hand-crafted sample — before the PR ships. Probe:
   ```
   body=$(curl -sk -u elastic:$PW "$ES/_license"); type=$(printf '%s' "$body" | sed -n 's/.*"type" *: *"\([^"]*\)".*/\1/p'); echo "type=[$type]"
   ```
   A parser that silently mis-extracts a field either re-runs a mutation on every converge (false-negative idempotency) or permanently skips a required mutation (false-positive) — both look clean in the PR diff and only misbehave on the real target. Sibling failure mode: `~/.claude/rules/ruby.md` "Guard must be evaluatable under mitamae's actual runtime privilege" (guard can't even run, vs. this — guard runs but parses wrong).

6. **Secret-placeholder token appears exactly once in a globally-substituted template**: any committed template with a placeholder (`@@KEY@@`, `{{SECRET}}`, …) rendered via global substitution (`sed 's/…/…/g'`, `envsubst`) must have that token appear ONLY at its intended substitution site. Probe:
   ```
   git diff origin/main...HEAD -- '*.toml' '*.tmpl' '*.yml' '*.sh' | grep -oE '@@[A-Z_]+@@|\{\{[A-Z_]+\}\}' | sort | uniq -c
   ```
   A count > 1 for the same token means a second mention (typically an explanatory comment) is also replaced by the global sed, leaking the real secret into the rendered file's comment. Fix: describe the mechanism without repeating the literal token ("the placeholder above", or abbreviate `@@...@@`). Pairs with the "no secret in git" rule — the committed template stays secret-free, but a stray token in prose defeats that at render time.

7. **A templated `execute` command body must be RENDERED and RUN, not just `ruby -c`'d**: any `command` built from a heredoc with `#{}` interpolation that also contains `$`, `%`, backticks, or nested quotes needs its rendered shell text extracted and executed in a scratch dir before the PR ships. `ruby -c` only parses the outer Ruby — it cannot see mruby-absent methods, `%`-operator collisions, or shell quoting traps. `mitamae --dry-run` does not execute `execute` bodies either, so it catches none of these.

   Technique that works: write a stub DSL to a scratch file defining `execute` / `file` / `directory` / `remote_file` (and `MItamae.logger`, `node`) as capture functions that append their attributes to an array, `eval` the cookbook against it, dump the captured `command` strings to JSON, then pipe each one into `/bin/sh` inside a `mktemp -d` — retargeting absolute paths to the scratch dir first. Judge by inspecting the RESULT (`ls -l`, `cat`, a `grep -c`), not by exit 0.

   Four bugs this catches that nothing else does (origin: 2026-08-01 sh1-cloud):
   - `Integer#zero?` — absent in mruby; `ruby -c` (CRuby) accepts it, only a real mruby run raises `NoMethodError`
   - a `command` built with Ruby's `%`/`format` operator colliding with a literal `printf "%s"` in the same template → `ArgumentError: named<known> after unnumbered(1)` at compile time
   - `awk '{print $2}'` forced into double quotes inside a single-quoted `bash -c '…'`, so bash expands `$2`/`$10` as positional parameters before awk runs — silently empty output, no error at any layer
   - `chmod` placed before the `mv` that replaces the inode, so the mode change is discarded — visible only by running the script and checking the resulting mode

Implementation-level, distinct from the design-level `~/.claude/rules/adversarial-review.md`. Adversarial caught architecture bugs (TLS SAN, IAM size, JWKS fetch loop); these 7 checks catch implementation bugs that surface only at apply time.

## Origin

2026-05-09 6 sequential fix PRs for bugs all 4 checks catch at PR time.
2026-07-11 `ensure_basic_license()` sed parse verified against the live ES `_license` response before PR #731 shipped — no bug this time, but no checklist item required it either (check 5 added).
2026-07-23 `@@LITELLM_API_KEY@@` repeated in a codex preamble comment; the render-time `sed -g` replaced it too, leaking the real LiteLLM key into the generated `~/.codex/config.toml` comment (zp-SHIN #83). Check 6 added.
2026-08-01 sh1-cloud GCE provisioning — 4 bugs in one new cookbook (mruby method gap, `%`/printf collision, awk/bash positional collision, chmod-before-mv), all passed `ruby -c`; each was found only by rendering through a stub DSL and executing the extracted shell. Check 7 added.
