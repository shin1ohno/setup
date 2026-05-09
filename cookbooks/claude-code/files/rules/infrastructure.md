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
