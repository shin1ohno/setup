# TODO

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
