# TODO

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
