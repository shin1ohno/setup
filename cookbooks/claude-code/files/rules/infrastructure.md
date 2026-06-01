---
globs: ["*.yaml", "*.yml", "*.tf", "Dockerfile", "docker-compose*.yml"]
---

# Infrastructure File Guidelines

This file is the always-loaded summary. Long examples + origin notes are in `~/.claude/rules/infrastructure-detail.md` (NOT auto-imported — load on demand via Read tool when a section pointer matches the current task).

- Always verify changes with dry-run / plan before applying
- Never hardcode secrets, tokens, or passwords — use environment variables or secret management
- Validate YAML/HCL syntax before committing
- Document non-obvious configuration choices with comments

**Topic-specific rules** (split out 2026-05-07 to keep this file scannable):

- AWS / IAM / SSM / Terraform — see `~/.claude/rules/aws-iam.md`
- PVE LXC operational gotchas — see `~/.claude/rules/pve-lxc.md`
- Docker Compose patterns — see `~/.claude/rules/docker-compose.md`
- Tailscale routing — see `~/.claude/rules/tailscale.md`

## Blast Radius Awareness

When modifying infrastructure, always evaluate whether the change triggers resource recreation or just in-place update.

- **Before adding logic to a provisioning script** (user_data, cloud-init, etc.): check whether that script's content hash feeds into a replace trigger. If it does, the change will destroy and recreate the resource
- **Separate base infrastructure from application deployment**: OS setup, networking, and runtime installation belong in provisioning (runs at resource creation). Application code, configs, and container orchestration belong in a deploy step that can run independently without recreating the resource
- **Never mix change frequencies**: a file that changes weekly (app config) must not share a content hash with a file that should change rarely (OS bootstrap). If they are hashed together, the fast-changing file forces recreation of the slow-changing resource
- **When fixing a bug on a running instance**: determine whether the fix belongs in the base provisioning layer or the application deploy layer. Defaulting to the provisioning script because "it's already there" creates coupling that causes unnecessary recreation later

## Config File Merge Semantics

Before syncing a managed config file (settings.json, YAML with list fields, etc.) where the deploy logic merges the cookbook source into an existing file, identify how each field is merged:

- **Union (set-like)**: array entries are deduplicated but never removed. A cookbook author who deletes an entry does NOT cause that entry to disappear from the deploy target — it persists in `existing` and is re-added on every run. Requires a one-time manual cleanup on the deploy target
- **Replace (overwrite)**: the cookbook value wholly replaces the existing value. Entries in the deploy target but absent from the cookbook are silently deleted on the next run
- **Deep-merge (object union)**: nested objects are merged key-by-key; behavior for each leaf field still falls into one of the above

In the plan, state the merge mode for every field being changed. For union fields, include the manual-cleanup command (e.g., `jq 'del(.permissions.allow[] | select(...))'`) as an explicit plan step — never assume a cookbook deploy will remove stale entries.

## Deploy-Only Change Tracking

When modifying files directly in `~/deploy/` (not managed by a cookbook):

1. **Prefer cookbook**: if a cookbook exists for the service, make the change there instead
2. **If no cookbook exists**: make the change in `~/deploy/`, but immediately save the change details to Cognee (what was changed, why, and the file path) so it can be reproduced if the deploy directory is rebuilt
3. **Flag for future cookbookification**: note in the cognify entry that this change is unmanaged and should be moved to a cookbook when one is created

Deploy directories can be rebuilt from scratch. Untracked changes there are silently lost.

## Commit Timing for Cookbook Changes

After implementing a cookbook change:
1. Run mitamae dry-run (via mitamae-validator agent)
2. If dry-run passes: commit immediately — do not wait for deploy or user prompt
3. If dry-run fails: fix and retry, then commit

Dry-run passing is the commit gate for cookbook changes. Never leave cookbook changes uncommitted after a passing dry-run.

## Cross-OS Scope Gate Before Cookbookifying a Hotfix

When codifying a manual fix into a cookbook, before writing the resource block, identify the target host(s) the cookbook actually runs on and confirm the fix applies to that OS. The fix's host (where the manual hotfix worked) is not always representative of every host the cookbook covers.

Before adding to a cookbook, answer:

1. **Which repo owns this fix?** List the candidate repos (`setup` for personal Linux/macOS, `home-monitor` for AWS EC2, `edge-agent` for embedded targets). Don't default to "wherever I saw the manual fix" — pick the cookbook whose target hosts have the failing condition
2. **What OS / package manager / init system does the failing condition require?** `dpkg-divert` is Debian/Ubuntu only. `systemd-resolved` shipping a `resolvconf` shim is recent Ubuntu only. Amazon Linux 2023 doesn't have either
3. **Does the cookbook run on hosts that don't satisfy the precondition?** If yes, gate the resource with `only_if` so it skips on non-matching hosts. Don't rely on silent failure — write an explicit guard
4. **State the target OS in the commit message** ("Ubuntu 24.04 ships ..."), not just the symptom

Detail (anti-pattern + origin): see `~/.claude/rules/infrastructure-detail.md#cross-os-scope-gate`.

## Long-Running Operations

`terraform plan`, `terraform apply`, and other commands that typically take 30+ seconds must run in a background sub-agent (`run_in_background: true`) so the main conversation remains interactive. Pattern:

1. Launch a background agent that runs the command and parses the output
2. Continue interacting with the user (answer questions, start other work)
3. When the agent completes, present the results and ask for next steps

This applies to: `terraform plan/apply`, `docker build`, long test suites, and any command where the user cannot usefully intervene mid-execution.

## Per-Device Identity Probe Before Cookbook Configuration

Before writing any cookbook resource that keys off a host's identity — hostname match in a device registry (`devices.json`, `node_map`, YAML host dict), user-home path, SSH login user, or per-device SSM parameter name — run a one-shot probe on the actual target host:

```bash
ssh <target> 'echo "hostname-s: $(hostname -s)"; echo "scutil HostName: $(scutil --get HostName 2>/dev/null)"; echo "user: $(whoami)"; echo "home: $HOME"'
```

Three values that diverge from cookbook assumptions most often:

1. **`hostname -s`** — macOS factories set this to a hardware serial (e.g. `XMHTM6QVQX`) before the user assigns a friendly name. `scutil --get ComputerName` returns the friendly name; mitamae's `hostname -s` runs the BSD utility and gets the unmodified short hostname
2. **`whoami`** — admin accounts on shared/work-issued Macs may differ from the personal username assumed in the cookbook (e.g., `sh1` vs `shin1ohno`)
3. **`$HOME`** — on some LXC templates, `root` has `HOME=/` or `HOME=/root` depending on whether the template populated `/etc/passwd` for the UID

Never write a `node[:hostname]` match expression or `ssh_user` field from memory or earlier documentation — SSH-probe and use what it actually reports. If devices.json (or equivalent) needs to track a host whose conceptual name diverges from `hostname -s`, add an explicit override field (`hostname`, `aliases`) and document the divergence in the entry.

Detail (origin): see `~/.claude/rules/infrastructure-detail.md#per-device-identity-probe`.

## Incident First Response

When a user reports any service or application misbehavior (slow, unavailable, failing):
1. Run `systemctl --failed` and check OOM kills in journal before diagnosing application logic
2. Check `journalctl -u <service> -n 50 --no-pager` for the affected service
3. Report findings **with a concrete fix plan** for review — never present findings alone without actionable next steps. The cause may be OS-level, not app-level

## Physical Network Device Pre-Plan SNMP Probe (YAMAHA RTX et al)

Before writing any terraform resource for a CLI-driven physical network device (YAMAHA RTX, Cisco, Juniper), the firmware imposes constraints invisible to the terraform provider's plan output. Surface them at plan phase via SSH probe, not after `terraform apply`. Each unprobed constraint typically costs one PR cycle.

Required probes (run once per device family before plan, capture outputs in the plan file):

1. **Firmware revision** — `ssh ... "show environment | head -3"`
2. **SNMP version reachability** — `snmpget -v 1` and `-v 2c` against `sysName.0` (RTX1210 Rev.14.01.42 silently drops v2c)
3. **ifTable vs ifXTable** — `snmpwalk -v 1 ... 1.3.6.1.2.1.31.1.1 | wc -l` (0 lines → no 64-bit counters; use `ifInOctets` / `ifOutOctets`)
4. **SNMP walk duration** — `time snmpwalk -v 1 ... 1.3.6.1.2.1.2.2.1` (sets Prometheus `scrape_timeout = 3 × walk_time`, `scrape_interval = 2 × scrape_timeout`)
5. **Existing SNMP config** — `ssh -tt + administrator + show config | grep snmp` to surface community-length / syslocation-token constraints

**Scrape_timeout sizing**: for a 7s walk → `scrape_timeout: 25s`, `scrape_interval: 60s`. Adding scrape_timeout as a hotfix later costs a separate PR + Prometheus reload.

Detail (full bash blocks + RTX1210/RTX830 constraint table + origin): see `~/.claude/rules/infrastructure-detail.md#physical-network-device-snmp-probe`.

## Blocked Command Boundary

When a command is blocked by any permission restriction — `sudo` required, tool-permission denied, project hook guard (e.g., mitamae dry-run guard), or user-declined approval — immediately present the blocked command prefixed with `!` so the user can run it in-session:

1. Present `! <command>` verbatim — do not add it to a "remaining tasks" list, do not describe it in prose without the `!` prefix
2. Continue with other non-blocked work in parallel while waiting for the user to run it
3. After the user runs it, verify the result before moving on

Applies equally to sudo, project-hook guards, and `deny`-listed Bash patterns.

## systemd Timer Verification Gate

After creating or modifying a systemd timer (cookbook deploy, manual install, drop-in override), the verification step is NOT `systemctl is-active <name>.timer`. It is:

```
systemctl show <name>.timer --property=Trigger
```

A future timestamp (`Trigger: Sat 2026-05-09 08:08:21 UTC`) = the timer will fire. `Trigger: n/a` = the timer's trigger condition cannot be evaluated; **the timer is enabled and active but will never fire**. `is-active` returns `active` either way.

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

This rule exists because the 2026-05-09 tailscale route-fix timer session shipped `OnUnitActiveSec=60s` on `Type=oneshot` (PR #253). The unit reported `active` but had `Trigger: n/a` — the "fix" never fired. Three sequential PRs (#253 / #257 / #259) were needed to fully close the failure class. A single `systemctl show --property=Trigger` probe after PR #253 would have caught it before merge.

## Auto-mitamae Fleet Cookbook Validation — Canary Before Fleet

When validating a cookbook fix on ONE host before fleet-wide rollout, the auto-mitamae orchestrator (driven by **cron** on the monitoring LXC — `/etc/cron.d/auto-mitamae-orchestrator`, drift-checker every 2 min + orchestrator every 5 min — NOT a systemd timer) will SSH-push `mitamae-runner` and revert your test config within minutes. The runner resets each host's `/root/setup` to `origin/main` (`git fetch + reset --hard + checkout <sha>`, NOT `git pull` — the repo is detached HEAD) and re-applies. So an unmerged fix on a feature branch is reverted on the next cycle.

Pause → validate → resume:

1. **Pause** the orchestrator on the host that runs it (the monitoring LXC; reach via the PVE host): move its cron file aside — `pct exec <monitoring-ct> -- mv /etc/cron.d/auto-mitamae-orchestrator /root/PAUSED.cron`. Confirm no `mitamae-runner` is mid-run first.
2. **Apply to the canary only**: get the change onto the canary's `/root/setup` (scp + `pct push`, or checkout the branch) and run `./bin/mitamae local pve/lxc-<name>.rb` inside the CT. The canary host is flagged `canary: true` in the orchestrator's `hosts.json`.
3. **Verify FUNCTIONALLY** (not `systemctl is-active`): e.g. `elastic-agent status` HEALTHY + ES doc-count advancing.
4. **Merge the cookbook PR to `main` FIRST, then resume** (restore the cron file). The orchestrator pulls from `origin/main`, so resuming before merge reverts the canary too. After resume, trigger one immediate cycle (run `drift-checker.sh` then `orchestrator.sh`) for fast rollout instead of waiting for the 5-min cron — the canary gate (canary applies first, fleet only if it succeeds) protects the rest of the fleet.

This pattern exists because the 2026-06-01 elastic-agent `processors:` schema fix (PR #412) needed the orchestrator paused during the CT 111 canary validation, or it reverted the test config before the functional health check completed.

## "Known Limitation" Comments Are Incomplete Fixes

When writing an inline comment in a cookbook, systemd unit, or config file that contains any of these phrases — or their semantic equivalents — STOP and treat the fix as incomplete:

- "manual restart required"
- "fires only at boot"
- "does not catch runtime re-injection"
- "requires operator intervention when X"
- "only works on first boot"
- "will not auto-recover"
- "after Y happens, run Z manually"

These phrases describe a **known failure class** that the current fix does not cover. Shipping the fix with such a comment is acceptable ONLY when both:

1. The uncovered class is explicitly out of scope for the current PR (stated in the PR description, not just inferred)
2. A `TODO.md` entry is created in the same commit naming the failure class, when it would trigger, and the concrete first step to close the gap

If neither condition holds — not out of scope, no TODO entry — the comment is deferred design debt that will silently regress in production until someone re-investigates the same symptom.

**Action gate** when you are about to write such a comment:

1. State the failure class in one sentence: "This fix does not handle X."
2. Is X out of scope for this PR?
   - YES → write the TODO.md entry first, then the comment, then ship
   - NO → fix X in this PR before merging
3. Never let "we'll get to it later" be the unstated third option

This rule exists because setup PR #174 (tailscale route-fixup oneshot, 2026-05-07) shipped a self-documented "manual restart required when tailscale re-injects routes at runtime" comment with no TODO entry. The comment was accurate. The fix regressed at 02:00 on 2026-05-09 when tailscale re-injected routes mid-session, and 3 new PRs (#253 / #257 / #259) were needed to convert the boot-only oneshot into a proper self-healing timer — work that PR #174's author had already identified as necessary at the moment of writing the comment.
