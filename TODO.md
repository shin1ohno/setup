# TODO

## H2: MCP auth-proxy resource isolation (HELD — audience enforcement infeasible)

Status 2026-06-07: investigated via live log-first observation; **audience
enforcement is NOT viable** with current token issuance. Held as Low-risk
known-limitation in this single-user deployment. Re-evaluate if the
deployment ever becomes multi-tenant.

- Vuln: the cognee + ai-memory auth-proxies pass `options={"verify_aud":
  False}` — no resource isolation. Confirmed live: `cognee/mcp` accepts a
  `roon-mcp`-audience token (HTTP 200). Files:
  `cookbooks/{cognee,ai-memory}/files/auth-proxy/proxy.py`.
- WHY ENFORCEMENT IS INFEASIBLE (log-first observation, aud-logging temped
  into the cognee proxy then reverted): the real claude.ai token carries an
  **empty** aud — `Authenticated POST /mcp (sub=sh1@mercari.com aud=[])`.
  The monitoring prober (client_credentials) carries `aud=["cognee"]`
  (bare). PyJWT `jwt.decode(audience=X)` requires the aud claim present and
  containing X, so ANY enforced value (full-URL OR bare) raises
  MissingRequiredClaim → 401 → breaks the user's cognee/memory MCP access.
  The strict full-URL fix is preserved on git tag `h2-audience-fix` but must
  NOT be deployed.
- WHY LOW NOW: only `sh1@mercari.com` passes the consent ALLOWED_EMAILS
  gate, so the cross-resource-reuse gap (a cognee token also works on
  memory) requires a token leak AND a second principal to isolate from —
  the latter does not exist. Defense-in-depth gap, not a multi-tenant
  isolation failure.
- OPTIONS to actually close it (pick when revisiting; each needs design):
  1. RFC-8707: make claude.ai send `resource=https://mcp.ohno.be/<svc>` and
     hydra/consent populate aud from `grant_access_token_audience`, THEN
     enforce `audience` in the proxies. Correct but largest scope.
  2. Scope-based isolation (mint/enforce a per-resource scope claim) — first
     confirm what `scope` a real claude.ai token carries.
  3. Keep as documented known-limitation (current choice).
- First step when revisiting: re-run the log-first probe to confirm aud is
  still empty, then pursue option 1 or 2. Probe recipe: on CT111 source
  `/etc/mcp-probe/probe.env`, mint via client_credentials, base64-decode the
  JWT middle segment; for a REAL token, temp-add aud logging to the cognee
  proxy `handle()` Authenticated log line and trigger one claude.ai request.
- Note (separate, pre-existing): memory MCP (CT107) was observed DOWN
  (HTTP 000 at /memory/mcp) during this session — unrelated to H2.

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
