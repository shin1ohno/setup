# Infrastructure — Examples & Origin Notes

This file is the detail companion to `~/.claude/rules/infrastructure.md`. The summary file holds the rule statements and minimal probe/checklist; this file holds anti-patterns, full bash blocks, lookup tables, and origin paragraphs.

Anchor convention: each section's heading slug matches the pointer line in the summary file.

## cross-os-scope-gate

**Anti-pattern**: discovering a Linux-specific fix on `pro` and adding it unguarded into a cookbook that also runs on macOS or AL2023. The wrong-OS branches will either silently no-op (best case) or fail loudly on every dry-run (worse case, blocks unrelated work).

This rule exists because the 2026-04-26 session correctly identified that the `dpkg-divert` fix belonged in `setup/cookbooks/tailscale/` (Ubuntu hosts), not `home-monitor/scripts/tailscale_setup.sh` (Amazon Linux 2023 EC2). The decision was sound — codifying the pattern so the OS-scope question is asked before, not after, picking a destination.

## per-device-identity-probe

This rule exists because setup PR #142 (2026-05-06) was required after `air`'s ssh-keys cookbook silently skipped its run (`hostname '<serial>' not in devices.json, skipping`). devices.json had `name: "air"` (= old conceptual name) + `ssh_user: "shin1ohno"` (= the user's other-machine convention), but the actual Mac reported `hostname -s = XMHTM6QVQX` (factory serial) + `whoami = sh1`. Both mismatches were invisible until per-device verification surfaced them. A 2-second probe at the start of Phase 2 per-device work would have caught both before any cookbook code was written.

## physical-network-device-snmp-probe

**Required probes** (run once per device family before plan, capture outputs in the plan file):

```bash
# 1. Firmware revision — identifies model-specific capability gaps
ssh shin1ohno@<device> -i <key> "show environment 2>/dev/null | head -3"

# 2. SNMP version reachability — RTX1210 Rev.14.01.42 silently drops v2c
docker run --rm --network host alpine:3.20 sh -c \
  "apk add --quiet net-snmp-tools && \
   echo === v1 ===; snmpget -v 1 -c <community> -t 5 -r 1 <device-ip> sysName.0; \
   echo === v2c ===; snmpget -v 2c -c <community> -t 5 -r 1 <device-ip> sysName.0"

# 3. ifTable vs ifXTable — RTX1210 firmware lacks ifXTable (HC 64-bit counters)
snmpwalk -v 1 -c <community> <device-ip> 1.3.6.1.2.1.31.1.1 2>&1 | wc -l
# 0 lines → use 32-bit ifInOctets/ifOutOctets in generator.yml; never ifHC*

# 4. SNMP walk duration — sets Prometheus scrape_timeout
time snmpwalk -v 1 -c <community> <device-ip> 1.3.6.1.2.1.2.2.1 > /dev/null
# scrape_timeout = 3 × walk_time, scrape_interval = 2 × scrape_timeout (per job)

# 5. Existing SNMP config — surface community length / location syntax constraints
ssh -i <key> shin1ohno@<device> -tt <<EOF
administrator
<admin-pw>
show config | grep -i snmp
exit
EOF
```

**RTX1210 Rev.14.01.42 / RTX830 Rev.15.02.31 known constraints** (codified from 2026-05-07 deployment):

| Constraint | Symptom | Fix |
|---|---|---|
| Community string ≤ 16 chars | `エラー: コミュニティ名称が認識できません` on apply | `random_password { length = 16 }` |
| `snmp syslocation` single token only | `エラー: パラメータの数が不適当です` on apply | `location = "Ebisu"` (no spaces) |
| `snmp host any` ACL not in `rtx_snmp_server` schema | SNMP daemon ignores all queries silently | SSH manual: `snmp host any` + `snmpv2c host any` + `save` |
| RTX1210 firmware: SNMPv2c silent drop | snmpwalk -v2c times out; v1 works | snmp_exporter `auths.<name>.version: 1` |
| RTX1210 firmware: no ifXTable | `ifHC*` counters return empty for hnd | generator.yml walk: `ifInOctets` / `ifOutOctets` (32-bit, RFC 1213) |
| terraform-provider-rtx itm SSH session start fails | `failed to start shell: EOF` immediately after handshake | manage SNMP/syslog manually via SSH; no `provider "rtx" { alias = "itm" }` |

**SNMP scrape_timeout sizing** (Prometheus job): default 10s is too low for SNMP walks on physical network devices. Measure once per device:

```bash
time snmpwalk -v 1 -c <community> <device-ip> 1.3.6.1.2.1.2.2.1 > /dev/null
```

Set `scrape_timeout: 3 × walk_time` and `scrape_interval: 2 × scrape_timeout`. For a 7s walk: `scrape_timeout: 25s`, `scrape_interval: 60s`. Adding scrape_timeout as a hotfix later costs a separate PR + Prometheus reload.

This rule exists because the 2026-05-07 Phase A deployment hit each of these constraints sequentially, costing 5 separate PRs (#26 → #29 → #31 → #32 + setup #190/#197/#203). A 2-minute probe at plan time would have collapsed all five into a single PR.
