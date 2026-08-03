# TODO

## Elastic CA rotation is not detected by the cert skip_if guards (Medium)

The content-aware `skip_if` migration (PR "content-aware skip_if") changed the
two Elastic CA fetch gates from `File.exist?` to
`file_has_all?(path, ["BEGIN CERTIFICATE"])` —
`cookbooks/lxc-monitoring/default.rb` (`/data/monitoring/vector/elastic-ca.crt`)
and `cookbooks/elastic-agent/default.rb` (`/etc/elastic-agent/certs/ca.crt`).
That upgrade catches a truncated or error-text file, but **CA rotation is an
explicit non-goal of it**: an OLD but well-formed PEM still satisfies the
needle, so the gate keeps skipping.

- **Trigger**: Terraform rotates the CA in SSM `/monitoring/elastic/ca/cert`
  (ADR 0005 §認証 puts CA validity at 2 years) and every already-converged host
  keeps serving the old PEM. Vector's `[sinks.elasticsearch].tls.ca_file` and
  elastic-agent's `output.default.ssl.certificate_authorities` then fail TLS
  against the re-issued ES certs — a fleet-wide ingest outage that no cookbook
  apply self-heals, because the gate reports "already done".
- **Why the needle cannot fix it**: the guard is a *content-shape* check, not a
  *value-drift* check. Detecting rotation needs a comparison against the
  authoritative SSM copy, which the skip_if deliberately avoids (it would put an
  `aws ssm get-parameter` on every apply's compile path).
- **First step**: add a value-drift check comparing the SSM cert's serial to the
  locally installed PEM's — fetch the param, `openssl x509 -noout -serial` on
  both, and re-fetch when they differ. Put it in the converge-time `execute`
  (where the existing `sudo diff -q` guard already lives) rather than the
  compile-time skip_if, and share one implementation between the two cookbooks.
  Delete this entry in the resolving commit.

## docs/rust.md — apply the estate-lens retro's sandbox-EPERM addendum (Low)

From the 2026-07-24 claude-md-audit removal verification: the estate-lens
session (eefe318b, 2026-06-22〜24 — the only real Rust session in 30 days)
produced a retro proposing a High-priority rust.md addition about the cargo
sandbox-EPERM pattern (cargo build/test hitting `Operation not permitted`
under the Claude Code command sandbox and the correct retry shape). It was
never applied, and the 2026-07 rules→docs demotion of rust.md must not bury
it.

- First step: pull the exact proposed text from the estate-lens retro
  (session eefe318b transcript or its retro output), verify the pattern
  against the current sandbox behavior once, then add the section to
  `cookbooks/claude-code/files/docs/rust.md`. Delete this entry in that
  commit.

## H2: MCP auth-proxy resource isolation (REVIEW NEEDED — post-cognee-decommission)

Status 2026-07-05: the cognee LXC/cookbook was decommissioned and the
surviving shared auth-proxy is `cookbooks/lxc-es-memory/files/auth-proxy/
proxy.py` (es-memory / v2 "memory" MCP). This item was written 2026-06-07
against the now-deleted cognee + ai-memory proxies and its earlier "audience
enforcement infeasible" conclusion PRE-DATES the es-memory rewrite — the
surviving proxy has since grown a v2 audience/subject enforcement matrix, so
the security posture must be RE-AUDITED before acting. FLAGGED for human review.

- Original concern: the auth-proxies pass `options={"verify_aud": False}` on
  the raw JWT signature-decode path (still present in the es-memory proxy at
  ~lines 134/147), i.e. the decode itself does not check audience.
- Surviving state: the es-memory proxy now DOES add a v2 audience/subject
  enforcement matrix at authorization time — `client_credentials` grants
  require `aud ∩ MEMORY_AUDIENCES` AND `client_id ∈ ALLOWED_CLIENT_IDS`
  (else 403 forbidden_audience); `authorization_code` claude.ai tokens carry
  `aud=[]` so aud is not required on that path. Whether this already closes
  the original cross-resource-reuse gap needs a fresh audit against the
  current code.
- WHY LOW: only `sh1@mercari.com` passes the consent ALLOWED_EMAILS gate, so
  the cross-resource-reuse gap requires a token leak AND a second principal
  to isolate from — the latter does not exist. Defense-in-depth gap, not a
  multi-tenant isolation failure.
- OPTIONS if a gap remains after the re-audit (each needs design):
  1. RFC-8707: make claude.ai send `resource=https://mcp.ohno.be/<svc>` and
     hydra/consent populate aud from `grant_access_token_audience`, THEN
     enforce `audience` in the proxy. Correct but largest scope.
  2. Scope-based isolation (mint/enforce a per-resource scope claim) — first
     confirm what `scope` a real claude.ai token carries.
  3. Keep as documented known-limitation.
- First step when revisiting: re-run the log-first probe against the
  es-memory proxy to confirm current claim shapes (aud/scope on a REAL
  claude.ai token vs the monitoring `client_credentials` prober), then decide
  whether the v2 matrix already suffices or option 1/2 is still wanted.

## Fix RTX1210 DNS proxy AAAA NODATA

- Host: 192.168.1.253 (RTX1210)
- Symptom: AAAA queries hang ~5s instead of returning NODATA quickly.
  `getent ahostsv6 sts.ap-northeast-1.amazonaws.com` 5.037s; AWS CLI /
  boto3 dual-stack lookup ~16-18s per call → caused
  `auto-mitamae-orchestrator` cycles to stall (2026-05-17 49 min outage).
- Workaround in place: `cookbooks/dns-prefer-ipv4` appends
  `options no-aaaa` to `/etc/resolv.conf` fleet-wide. Once the upstream
  fix lands the cookbook can be removed (or kept as defense-in-depth).
- First step: home-monitor 側 RTX terraform / config を確認。
  `~/.claude/rules/infrastructure.md` "Physical Network Device Pre-Plan
  SNMP Probe" に沿って RTX へ SSH probe → `show config | grep dns` で
  current `dns server select` を把握 → upstream DNS を IPv6 NXDOMAIN を
  即返すリゾルバ (1.1.1.1 / 8.8.8.8 直結) に切替、または `dns server
  select` で AAAA を local handle するルール追加。home-monitor 側で PR。

## auto-mitamae alert delivery — fired but unnoticed for 11 days

- Symptom: auto-mitamae ran silently dead 2026-05-19 → 2026-05-30 (cron
  renamed to `.DISABLED-by-praeco-incident`, never reverted). Fleet frozen
  at SHA 8bc55eb while origin/main moved to c77da39.
- Root of the *invisibility*: `AutoMitamaeApplyStale` and
  `AutoMitamaeOrchestratorStuck` alerts (cookbooks/lxc-monitoring/files/
  alerts/auto-mitamae.yml, `time()-last_apply_timestamp > 900`) EXIST and
  must have been firing the whole 11 days — but no one was notified. The
  rules are fine; the Alertmanager routing / notification pipeline is the gap.
- First step: confirm whether Alertmanager is deployed + has a working
  receiver (Slack/email/etc.). `ssh root@192.168.1.10 'pct exec 111 -- bash -lc
  "docker ps | grep -i alertmanager; cat ~/deploy/monitoring/alertmanager*.yml
  2>/dev/null"'`. If no Alertmanager, Prometheus alerts only show in the UI —
  decide a notification channel and wire it.
- Recovery already done (2026-05-30): cron re-enabled, fleet converged 18/18,
  ES RED cluster fixed; resilience hardening in setup PR #394.

## auto-mitamae self-deadlock — disabled cron cannot self-heal

- The monitoring apply that recreates `/etc/cron.d/auto-mitamae-orchestrator`
  is itself driven by that cron. Once disabled, nothing restores it.
- Intentional disables (`.DISABLED` rename) must NOT be auto-reverted, so the
  fix is detection, not auto-recreation: the staleness alert above + a working
  delivery pipeline is the correct backstop. No code change until alert
  delivery (above) is confirmed working.

## self-heal-loops headless auth — OAuth token expiry on pro-dev

- The self-heal cron loops (`cookbooks/self-heal-loops`, CT 104) run headless
  `claude -p` as shin1ohno using `/home/shin1ohno/.claude/.credentials.json`.
  If that OAuth token expires and needs interactive re-auth, the cron silently
  starts failing (logged in `~/.claude/logs/self-heal-{create,resolve}.log`,
  `rc!=0`).
- Reason: headless cron has no way to complete an interactive `claude` login.
- First step for permanent unattended operation: decide whether to switch the
  loops to an `ANTHROPIC_API_KEY` (set in the cron env / wrapper) instead of the
  interactive OAuth token — a billing/account-policy decision. Until then,
  monitor the loop logs and re-auth `claude` on pro-dev when a run logs an auth
  failure. Consider a node_exporter textfile metric off `…/self-heal-*.last`
  (last-run age) + a Prometheus staleness alert, mirroring SelfHealObserverStale.

## Automate elastic-billing-reader key rotation (AWS billing → Kibana)

- The `elastic-billing-reader` IAM user (home-monitor `pve-monitoring-aws-billing.tf`)
  uses a SINGLE static access key with no automated rotation. Shipped this way
  deliberately (read-only billing scope; matches the `elasticsearch-snapshot`
  precedent) plus a CloudTrail→SNS audit hook on key changes.
- Two coupled gaps to close when automating rotation:
  1. Adopt the `pve-bootstrap-ssm` primary/secondary 2-key harness
     (`aws_iam_access_key for_each = ["primary","secondary"]` + SSM alias swap +
     `lifecycle { ignore_changes = [value] }`) for `elastic-billing-reader`.
  2. The env file is WRITE-ONCE for VALUE changes. `cookbooks/elastic-agent/
     default.rb` `require_external_auth(skip_if: ...)` is now content-aware for
     key ADDITION (regenerates when `AWS_ACCESS_KEY_ID=` is absent on the
     billing host), but a rotated key VALUE will NOT propagate to CT 111 until
     `/etc/elastic-agent/elastic-agent.yml.env` is regenerated. Manual rotation
     recovery today: `rm /etc/elastic-agent/elastic-agent.yml.env` on CT 111 +
     `mitamae local pve/lxc-monitoring.rb`.
- First step: lift the primary/secondary `for_each` + rotation block from
  `home-monitor/pve-bootstrap-iam.tf` into `pve-monitoring-aws-billing.tf`, then
  add a value-drift check to the elastic-agent env-generation `skip_if`.

## mini always-on power: enforce durability across macOS updates (Low)

Status 2026-07-04: fixed the #603 root cause (mini idle-slept because
`mac-settings` deployed but never executed `pmset -c sleep 0`). Added an
idempotent enforce-execute in `cookbooks/mac-settings/default.rb`, so a
`darwin.rb` apply now converges the always-on power settings.

- RESIDUAL GAP: Macs are outside the auto-mitamae fleet (manual apply only), and
  a macOS **major update** can reset pmset. Between the reset and the next manual
  `darwin.rb` apply, mini would idle-sleep again and #603-class alerts would flap.
- First step when revisiting: decide the enforcement channel — either (a) bring
  mini under a periodic self-apply (a user-mode launchd timer running
  `mitamae local darwin.rb`, per `~/.claude/rules/ruby.md` "automating mitamae"),
  or (b) a tiny standalone launchd job that re-asserts `pmset -c sleep 0` on load.
  (a) is broader but keeps mini current with all cookbooks; (b) is minimal.

## available-skills list diet — gws-*/recipe-*/persona-* occupy the session skill listing (Low)

From the 2026-07-06 claude-md-audit critic pass: the per-session available-skills
reminder lists ~100 deployed skills, dominated by the gws plugin families
(`gws-*`, `recipe-*`, `persona-*`). Their descriptions consume always-loaded
context the same way rules/ files did before #639/#666, but they were out of
scope for the rules diet.

- Reason deferred: the skills come from plugins/marketplaces, not the cookbook
  deploy lists — the diet mechanism is enabledPlugins scoping, not file deletion.
- First step: measure the actual byte share of the skill listing in a fresh
  session's system prompt, then trial-disable the `recipe-*`/`persona-*`
  families in `enabledPlugins` (keep `gws-*` operational skills) and confirm
  nothing in daily flows regresses.

## auto-memory stale review — Cognee-referencing memories post-#656 (Low)

From the 2026-07-06 claude-md-audit critic pass: project auto-memory dirs
(`~/.claude/projects/*/memory/`, 4 projects) contain entries written before the
Cognee retirement (#656) and the local-es-memory migration — e.g. zp-SHIN's
`loop-engineering-adoption` / `mcp-health-monitor-loop` reference Cognee
pipelines and the old local MCP ports.

- Reason deferred: memories are per-project and self-correcting on next touch
  (the stale-recorded-constraints rule shipped in #695 mandates write-back on
  reversal), but a proactive sweep shortens the stale window.
- First step: `grep -rliE 'cognee|cognify|8001|8002' ~/.claude/projects/*/memory/`
  and update or delete each hit, syncing MEMORY.md index lines in the same pass.

## remindd daemon — connection/idle-timeout hardening (Low)

From the adversarial review of the `remindd` daemon (cookbooks/remind, added with
the daemon PR). The daemon has no idle/read timeout and no max-concurrent-connection
cap, so a slow or silent LAN client (slowloris) can hold connections and starve the
accept loop. Deferred deliberately: the daemon is LAN-bound on a trusted home network
(Mac mini), single-user, so the exposure is a compromised/buggy LAN device only — out
of scope for the initial PR.

- Reason deferred: trusted-LAN posture makes this low-likelihood; the Hummingbird 2.x
  config API for read/idle timeout + max connections wasn't confirmed at implementation
  time and adding it unverified risked the build.
- First step: confirm the Hummingbird 2.x `Application`/server configuration knobs for
  idle/read timeout and max in-flight connections (swift-nio `ServerBootstrap`
  child-channel options surfaced via HB config), set a modest idle timeout (~30s) and
  connection cap in `cookbooks/remind/files/daemon/Sources/remindd/main.swift`, and
  add a slowloris probe to the verification steps.

## elastic-agent — two Linux defects that abort the whole apply (Medium)

Found by an adversarial review while making `linux.rb` converge on a keyless cloud
VM. The `sh1-cloud` profile now skips `elastic-agent`, so neither defect affects
that host any more — but both still stand for bare-metal / LXC Linux.

1. `execute "render elastic-agent.yml"`'s command string begins with
   `set -euo pipefail` (`cookbooks/elastic-agent/default.rb:543`). mitamae runs
   `command` through `/bin/sh`, which is dash on Debian/Ubuntu, so this exits 2
   with `set: Illegal option -o pipefail`. Its `only_if` is
   `test -f <tmpl> && test -d /etc/elastic-agent`, i.e. it fires on any Linux host
   that already has the agent installed. The resource's own `not_if` carries a
   comment about dash lacking process substitution, so the dash constraint was
   known when it was written. The same class was already fixed in
   `cookbooks/{codex-cli,mcp,herdr,terraform}`. This is NOT the last unwrapped
   site — see the `lxc-elasticsearch / lxc-kibana / lxc-monitoring` entry below
   for nine more, and `ssh-keys` for a tenth.
2. The apt block (`default.rb:313-355` — install prerequisites, add key, add repo,
   `apt-get update`, install, `apt-mark hold`) runs privileged commands with no
   `user` attribute and no `sudo` in the command string. Fine where
   `mitamae-runner` applies as root; fails on a Linux host applying as a regular
   login user. The same file already uses `user "root"` for its darwin path
   (`:176`, `:183`), so the idiom is in place.

- Reason deferred: both fixes are one-liners, but neither is verifiable from the
  work Mac — the affected hosts (ES LXCs, bare-metal `pro`) are on the home LAN and
  unreachable from here (`ssh pro` → DNS failure, `neo.local` → connect timeout).
  Shipping an unverified change to the cookbook that feeds the monitoring cluster
  is worse than leaving a recorded defect. Also out of scope for the PR that
  surfaced it, which is about cloud-VM convergence.
- First step: from a host on the home LAN, run `./bin/mitamae local linux.rb
  --dry-run` and confirm whether the render resource is reached (that settles
  whether defect 1 is live fleet-wide or its `only_if` is simply unsatisfied). Then
  wrap the command in `bash -c '...'` per the herdr/terraform pattern, add
  `user node[:setup][:system_user]` to the six apt resources, and verify by
  dispatching `test-setup.yml` at `all-cookbooks`, which runs a non-sudo
  `./bin/mitamae local linux.rb` — exactly the non-root Linux profile defect 2
  fails under.

## ssh-keys — known_hosts keyscan is dash-fatal on Linux (Medium)

`cookbooks/ssh-keys/default.rb`'s step 5 builds `github_known_hosts_script` as a
heredoc beginning `set -euo pipefail` and passes it as a bare `command`
(`execute "register github.com host keys in known_hosts"`). mitamae runs `command`
through `/bin/sh`, which is dash on Debian/Ubuntu, so this exits 2 with
`set: Illegal option -o pipefail` and — no `ignore_failure` — aborts the rest of
`ssh-keys` and everything after it. Same class as the `elastic-agent` entry above
and as the already-fixed `cookbooks/{codex-cli,mcp,herdr,terraform}`.

Whether it is *live* is genuinely unclear and worth settling before touching it:
its `not_if` is `test -f known_hosts && grep -q '^github.com '`, so on any host
whose `known_hosts` already carries a github entry the resource never runs. A
Linux host that has been converging successfully for a long time may simply have
been seeded before the `pipefail` line was introduced.

The overlay's `cookbooks/gcp-ssh-keys` (kouzoh/zp-SHIN) deliberately carries its
own `bash -c`-wrapped copy of this script rather than reusing this one, and
records why in a comment — so the cloud box is unaffected either way.

- Reason deferred: unverifiable from the work Mac. The hosts that run `ssh-keys`
  past its AWS auth gate are the home-LAN LXCs and bare-metal `pro`, and neither
  resolves from here (`ssh pro` → DNS failure, `neo.local` → connect timeout).
  Changing the cookbook that distributes SSH keys to the whole fleet on an
  unverified hypothesis is the wrong trade.
- First step: on a home-LAN Linux host, `mv ~/.ssh/known_hosts{,.bak}` and run
  `./bin/mitamae local linux.rb --dry-run` to force the resource to be reached —
  that distinguishes "already seeded, never runs" from "live abort". If live, wrap
  in `bash -c '...'`; note the script uses `awk '{print $2}'`, which needs
  rewriting to `cut -d' ' -f2` under a single-quoted `bash -c` wrapper (bash would
  otherwise expand `$2` as a positional parameter), exactly as done in the
  overlay's copy.

## lxc-elasticsearch / lxc-kibana / lxc-monitoring — nine dash-fatal pipefail sites (Medium)

Found by auditing every commit of the 2026-07-30..08-02 window against its diff.
The `elastic-agent` entry above claimed to be the last unwrapped `pipefail` site
in the repo; it was already wrong when written (the very next PR recorded
`ssh-keys` as a second), and a full classification finds nine more. All nine are
the FIRST line of a bare `execute … command`, so on a Debian/Ubuntu host — where
mitamae runs `command` through `/bin/sh` = dash — they exit 2 with
`set: Illegal option -o pipefail`, and with no `ignore_failure` that aborts the
rest of the run:

| Site | Enclosing resource |
|---|---|
| `cookbooks/lxc-elasticsearch/default.rb:268` | `execute "render elasticsearch.yml"` |
| `cookbooks/lxc-elasticsearch/default.rb:294` | `execute "ensure elasticsearch.yml exists"` |
| `cookbooks/lxc-kibana/default.rb:330` | `execute "install Synthetics alerting (connector + Status + TLS rules)"` |
| `cookbooks/lxc-kibana/default.rb:346` | `execute "install process-liveness rules (~31 .es-query rules)"` |
| `cookbooks/lxc-kibana/default.rb:367` | `execute "install Stack Monitoring integration packages (EPM)"` |
| `cookbooks/lxc-monitoring/default.rb:430` | `execute "download dbip-city-lite GeoIP DB"` |
| `cookbooks/lxc-monitoring/default.rb:552` | `execute "fetch elastic CA cert from SSM"` |
| `cookbooks/lxc-monitoring/default.rb:586` | `execute "generate snmp.yml"` |
| `cookbooks/lxc-monitoring/default.rb:604` | `execute "ensure snmp.yml exists"` |

Firing conditions, read off the guards rather than assumed. The `render …` sites
are notify-driven and carry a `not_if` that diffs the freshly-rendered output
against the installed file, so a converged host skips them on every apply and
they fire the NEXT TIME THE TEMPLATE CHANGES. The `ensure … exists` sites carry
`only_if "… ! test -f <path>"`, so they fire on a FRESH LXC's first apply. That
is why a working cluster is not evidence against this: both classes are latent on
exactly the hosts that already converged.

`cookbooks/lxc-elasticsearch/default.rb:275-279` is the sharpest instance — its
comment correctly explains that mitamae evaluates `not_if` through dash and
rewrites the guard for dash compatibility, three lines below a `command` that
still opens with `set -euo pipefail`.

Detection: use `git grep -n pipefail`, NOT a `set -euo pipefail` literal. The
string `set -euo pipefail` does not contain the substring `-o pipefail` (the `-`
and the `o` are not adjacent), and `lxc-monitoring:430` uses the `set -uo
pipefail` variant, so both narrower patterns silently under-report. Classify each
hit by its enclosing construct before believing it: `cookbooks/gpg-backup:40,546`,
`cookbooks/s3-backup:56` and `cookbooks/lxc-pro-router:91` sit inside
`file … content` heredocs (shipped scripts with their own interpreter, not
mitamae `command` strings), and `cookbooks/tailscale:37` is inside a darwin-only
block where `/bin/sh` is bash in sh-mode and accepts the option. Those five are
NOT defects.

- Reason deferred: unverifiable and unfixable from this machine. All nine live on
  the home-LAN ES / Kibana / monitoring LXCs, which do not resolve from the cloud
  box (`air`, `ohnos-macbook` and `pro` all fail name resolution). Shipping an
  unverified change to the cookbooks that feed the monitoring cluster is the same
  trade already refused for the `elastic-agent` entry above.
- First step: from a home-LAN host, `pct exec <ct> -- /bin/sh -c 'set -euo
  pipefail'` to confirm dash rejects it on the actual template, then for each site
  wrap the command in `bash -c '...'` per the herdr/terraform pattern. Check each
  wrapped body for `awk '{print $N}'` first — bash eats `$N` as a positional
  parameter inside a single-quoted `bash -c`, so those need `cut -d' ' -fN`
  (same substitution the `ssh-keys` entry above records). Verify by touching a
  template input so the notify fires, and by applying to a fresh CT for the
  `ensure … exists` pair.
