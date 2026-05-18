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
