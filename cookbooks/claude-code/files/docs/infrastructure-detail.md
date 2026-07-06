# Infrastructure — Examples & Origin Notes

This file is the detail companion to `~/.claude/rules/infrastructure.md`. The summary file holds the rule statements and minimal probe/checklist; this file holds anti-patterns, full bash blocks, lookup tables, and origin paragraphs.

Anchor convention: each section's heading slug matches the pointer line in the summary file.

## cross-os-scope-gate

**Full 5-question checklist** (answer before writing the resource block):

1. **Which repo owns this fix?** List the candidate repos (`setup` for personal Linux/macOS, `home-monitor` for AWS EC2, `edge-agent` for embedded targets). Don't default to "wherever I saw the manual fix" — pick the cookbook whose target hosts have the failing condition
2. **What OS / package manager / init system does the failing condition require?** `dpkg-divert` is Debian/Ubuntu only. `systemd-resolved` shipping a `resolvconf` shim is recent Ubuntu only. Amazon Linux 2023 doesn't have either
3. **Does the cookbook run on hosts that don't satisfy the precondition?** If yes, gate the resource with `only_if` so it skips on non-matching hosts. Don't rely on silent failure — write an explicit guard
4. **State the target OS in the commit message** ("Ubuntu 24.04 ships ..."), not just the symptom
5. **Scripts shipped via `remote_file` / `files/`**: when the cookbook deploys a shell script to the target host, treat the script's external command dependencies as part of the OS scope check. Run `grep -E '\b(flock|timeout|sponge|tac|nproc|numfmt)\b' cookbooks/<name>/files/*.sh` — any hit in a cookbook targeting macOS is a portability risk. `mitamae --dry-run` does NOT execute the shipped scripts; runtime is the only gate unless you grep first. See `~/.claude/rules/shell.md` "macOS External-Command Audit for Ported Linux Scripts"

**Anti-pattern**: discovering a Linux-specific fix on `pro` and adding it unguarded into a cookbook that also runs on macOS or AL2023. The wrong-OS branches will either silently no-op (best case) or fail loudly on every dry-run (worse case, blocks unrelated work).

This rule exists because the 2026-04-26 session correctly identified that the `dpkg-divert` fix belonged in `setup/cookbooks/tailscale/` (Ubuntu hosts), not `home-monitor/scripts/tailscale_setup.sh` (Amazon Linux 2023 EC2). The decision was sound — codifying the pattern so the OS-scope question is asked before, not after, picking a destination.

## per-device-identity-probe

**Probe** (one ssh round-trip on the actual target host):

```bash
ssh <target> 'echo "hostname-s: $(hostname -s)"; echo "scutil HostName: $(scutil --get HostName 2>/dev/null)"; echo "user: $(whoami)"; echo "home: $HOME"'
```

Three values that diverge from cookbook assumptions most often:

1. **`hostname -s`** — macOS factories set this to a hardware serial (e.g. `XMHTM6QVQX`) before the user assigns a friendly name. `scutil --get ComputerName` returns the friendly name; mitamae's `hostname -s` runs the BSD utility and gets the unmodified short hostname
2. **`whoami`** — admin accounts on shared/work-issued Macs may differ from the personal username assumed in the cookbook (e.g., `sh1` vs `shin1ohno`)
3. **`$HOME`** — on some LXC templates, `root` has `HOME=/` or `HOME=/root` depending on whether the template populated `/etc/passwd` for the UID

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

## systemd-timer-verification-gate

**Common causes of `Trigger: n/a` for `Type=oneshot` services**:

- `OnUnitActiveSec=Ns` on `Type=oneshot` without `RemainAfterExit=true` — the unit's "active" window is essentially zero (transitions inactive → activating → deactivating → inactive in milliseconds), so "N seconds after last activation" produces no future timestamp. Fix: switch to `OnUnitInactiveSec=Ns` (measures from deactivation), OR add `RemainAfterExit=true` if the unit's idempotent contract allows it.
- `OnUnitInactiveSec=Ns` where the bound service has never deactivated — no reference point exists. Fix: combine with `OnBootSec=30s` AND `OnActiveSec=30s` so the first run is bootstrapped from boot OR timer-(re)start time.

**Recommended pattern** for "drop-in self-healing oneshot, ≤Ns latency":

```
[Timer]
OnBootSec=30s
OnActiveSec=30s
OnUnitInactiveSec=60s
Unit=<name>.service
```

`OnBootSec` covers cold boot. `OnActiveSec` covers `systemctl restart timer` after a cookbook update (where boot was hours ago). `OnUnitInactiveSec` is the recurring fire after the first run completes.

**Cookbook execute for installing/updating a timer** must include all four steps:

```
sudo systemctl daemon-reload && \
  sudo systemctl enable <name>.timer && \
  sudo systemctl restart <name>.timer && \
  sudo systemctl start <name>.service
```

`enable --now` is a no-op when the unit is already active — without `restart timer` the running timer keeps the old in-memory config after a cookbook update (the file on disk changes but nothing reloads it). `start service` immediately seeds the deactivation reference for `OnUnitInactiveSec`. Skipping either step works on first install but silently breaks every subsequent timer-body update.

**Service-side note**: when changing a `Type=oneshot` unit's `RemainAfterExit` flag (e.g., `true` → `false` to allow timer-driven re-firing), `systemctl restart <name>.service` is also required — `daemon-reload` updates the file body but the running service keeps its old in-memory state. A service stuck in `active (exited)` from a `RemainAfterExit=true` era never deactivates, so `OnUnitInactiveSec` never gets a reference. `systemctl start` is a no-op when active; only `restart` forces the transition through inactive.

Origin: 2026-05-09 `OnUnitActiveSec=60s` on `Type=oneshot` shipped `active` but `Trigger: n/a`, never fired (PRs #253/#257/#259).

## auto-mitamae-canary

Pause → validate → resume:

1. **Pause** the orchestrator on the host that runs it (the monitoring LXC; reach via the PVE host): move its cron file aside — `pct exec <monitoring-ct> -- mv /etc/cron.d/auto-mitamae-orchestrator /root/PAUSED.cron`. Confirm no `mitamae-runner` is mid-run first.
2. **Apply to the canary only**: get the change onto the canary's `/root/setup` (scp + `pct push`, or checkout the branch) and run `./bin/mitamae local pve/lxc-<name>.rb` inside the CT. The canary host is flagged `canary: true` in the orchestrator's `hosts.json`.
3. **Verify FUNCTIONALLY** (not `systemctl is-active`): e.g. `elastic-agent status` HEALTHY + ES doc-count advancing.
4. **Merge the cookbook PR to `main` FIRST, then resume** (restore the cron file). The orchestrator pulls from `origin/main`, so resuming before merge reverts the canary too. After resume, trigger one immediate cycle (run `drift-checker.sh` then `orchestrator.sh`) for fast rollout instead of waiting for the 5-min cron — the canary gate (canary applies first, fleet only if it succeeds) protects the rest of the fleet.

Origin: 2026-06-01 elastic-agent `processors:` schema fix — orchestrator reverted canary config before health check.

## known-limitation-comments

Phrases that signal a known failure class the current fix does not cover:

- "manual restart required"
- "fires only at boot"
- "does not catch runtime re-injection"
- "requires operator intervention when X"
- "only works on first boot"
- "will not auto-recover"
- "after Y happens, run Z manually"

**Action gate** when you are about to write such a comment:

1. State the failure class in one sentence: "This fix does not handle X."
2. Is X out of scope for this PR?
   - YES → write the TODO.md entry first, then the comment, then ship
   - NO → fix X in this PR before merging
3. Never let "we'll get to it later" be the unstated third option

Origin: 2026-05-07 "manual restart required" comment shipped with no TODO; the named failure class regressed 2 days later (PRs #253/#257/#259).
