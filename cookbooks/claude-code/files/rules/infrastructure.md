---
globs: ["*.yaml", "*.yml", "*.tf", "Dockerfile", "docker-compose*.yml"]
---

# Infrastructure File Guidelines

This file is the always-loaded summary. Long examples + origin notes are in `~/.claude/docs/infrastructure-detail.md` (NOT auto-imported — load on demand via Read tool when a section pointer matches the current task).

**Topic-specific rules** (split out 2026-05-07 to keep this file scannable):

- AWS / IAM / SSM / Terraform — see `~/.claude/rules/aws-iam.md`
- PVE LXC operational gotchas — see `~/.claude/docs/pve-lxc-detail.md`
- Docker Compose patterns — see `~/.claude/rules/docker-compose.md`
- Tailscale routing — see `~/.claude/docs/tailscale.md`

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

**Ruby `Hash#merge` gotcha**: `existing.merge(managed)` is **shallow** — only top-level keys merge. If `existing["k"]` and `managed["k"]` are BOTH Hashes, the result's `["k"]` becomes `managed["k"]` **wholesale**; every subkey present only in `existing["k"]` is lost. This is NOT a recursive union. Any nested-Hash field written by more than one actor (a public cookbook + a private overlay + interactive UI edits) needs an EXPLICIT per-field merge — `merged["k"] = existing.fetch("k", {}).merge(managed.fetch("k", {}))` — mirroring how a sibling field like `permissions` is already special-cased. Never assume bare top-level `Hash#merge` recurses. Origin: 2026-07 `~/.claude/settings.json` `enabledPlugins` — the shallow merge silently stripped an overlay-enabled plugin on every apply (shin1ohno/setup#611 added the explicit per-field merge; the private overlay also re-asserts its own entry).

In the plan, state the merge mode for every field being changed. For union fields, include the manual-cleanup command (e.g., `jq 'del(.permissions.allow[] | select(...))'`) as an explicit plan step — never assume a cookbook deploy will remove stale entries.

## Managed-File Ownership Gate

Before you Edit/Write a config file under `$HOME` that is OUTSIDE a git working tree (`~/ManagedProjects/*`), probe whether it is mitamae-managed:

    rg -l '<parent-dir>/<basename>' ~/ManagedProjects/setup/cookbooks/ ~/ManagedProjects/zp-SHIN/projects/mercari-setup/cookbooks/
    # e.g. rg -l 'zed/settings\.json' ...  — a bare basename (settings.json) false-hits everywhere, so probe on a path fragment.

- **Hit** → the file is a `template` / `remote_file` render target. A direct edit of the deploy copy is silently reverted by the next apply's re-render. Make the change in the cookbook source (business-specific values in the private overlay).
- **Emergency direct edit first** → state explicitly that it "disappears on the next apply", and leave a TODO to reflect it into the cookbook in the same turn (same shape as the `~/deploy/` memory-MCP record below).
- Existing individual cases are subsumed by this general rule: Dual-managed file (CLAUDE.md), Deploy-Only Change Tracking (`~/deploy/`, below).

**Where shared values live (first-driver ≠ owner)**: an env var / config value that more than one tool may read (`GITHUB_TOKEN` etc.) belongs in the consumer-set layer (shell `profile.d` / a generic cookbook), NOT the dedicated cookbook of whichever tool needed it first. Enumerate the tools that could reference it; if 2+, use the generic layer. Origin: 2026-06 mise `GITHUB_TOKEN` → zsh cookbook (setup#597).

### Deploy-Only Change Tracking (`~/deploy/` sub-case)

When modifying files directly in `~/deploy/` (not managed by a cookbook): prefer a cookbook if one exists; otherwise make the change in `~/deploy/` but immediately save the change details to the memory MCP via `ingest` (what changed, why, and the file path) so it can be reproduced if the deploy directory is rebuilt, and flag the change as unmanaged for future cookbookification. Deploy directories can be rebuilt from scratch — untracked changes there are silently lost.

## Commit Timing for Cookbook Changes

After implementing a cookbook change:
1. Run mitamae dry-run (via mitamae-validator agent)
2. If dry-run passes: commit immediately — do not wait for deploy or user prompt
3. If dry-run fails: fix and retry, then commit

Dry-run passing is the commit gate for cookbook changes. Never leave cookbook changes uncommitted after a passing dry-run.

## Cross-OS Scope Gate Before Cookbookifying a Hotfix

When codifying a manual fix into a cookbook, before writing the resource block, identify the target host(s) the cookbook actually runs on and confirm the fix applies to that OS — the host where the manual hotfix worked is not always representative of every host the cookbook covers (`dpkg-divert` is Debian/Ubuntu only; `systemd-resolved`'s `resolvconf` shim is recent-Ubuntu only; AL2023 has neither). If the cookbook runs on hosts that don't satisfy the precondition, gate the resource with `only_if` (an explicit guard, not silent failure), and state the target OS in the commit message ("Ubuntu 24.04 ships ..."), not just the symptom. For scripts shipped via `remote_file` / `files/`, audit their external-command deps for macOS portability (`mitamae --dry-run` does not execute shipped scripts) — see `~/.claude/rules/shell.md` "macOS External-Command Audit for Ported Linux Scripts".

Detail (5-question worked checklist + grep example + anti-pattern + origin): see `~/.claude/docs/infrastructure-detail.md#cross-os-scope-gate`.

## Per-Device Identity Probe Before Cookbook Configuration

Before writing any cookbook resource that keys off a host's identity — hostname match in a device registry (`devices.json`, `node_map`, YAML host dict), user-home path, SSH login user, or per-device SSM parameter name — SSH-probe the actual target host for `hostname -s`, `scutil --get HostName`, `whoami`, and `$HOME`. The three values that diverge from cookbook assumptions most often: `hostname -s` (macOS factories set a hardware serial before a friendly name), `whoami` (work-issued Macs use a different admin account, e.g. `sh1` vs `shin1ohno`), and `$HOME` (root's home varies by LXC template). Never write a `node[:hostname]` match or `ssh_user` field from memory or old docs — use what the probe reports; if a host's conceptual name diverges from `hostname -s`, add an explicit override field (`hostname`, `aliases`) and document the divergence in the entry.

Detail (probe one-liner + 3 divergence examples + origin): see `~/.claude/docs/infrastructure-detail.md#per-device-identity-probe`.

## Incident First Response

When a user reports any service or application misbehavior (slow, unavailable, failing):
1. Run `systemctl --failed` and check OOM kills in journal before diagnosing application logic
2. Check `journalctl -u <service> -n 50 --no-pager` for the affected service
3. The cause may be OS-level, not app-level. Report findings with a concrete fix plan.

## Physical Network Device Pre-Plan SNMP Probe (YAMAHA RTX et al)

Before writing any terraform resource for a CLI-driven physical network device (YAMAHA RTX, Cisco, Juniper), the firmware imposes constraints invisible to the terraform provider's plan output. Surface them at plan phase via SSH probe, not after `terraform apply` — each unprobed constraint typically costs one PR cycle. Probe once per device family (capture outputs in the plan file): (1) firmware revision, (2) SNMP version reachability (RTX1210 Rev.14.01.42 silently drops v2c), (3) ifTable vs ifXTable (0 ifXTable rows → no 64-bit counters; use 32-bit `ifInOctets` / `ifOutOctets`), (4) SNMP walk duration, (5) existing SNMP config (community-length / syslocation-token constraints).

**Scrape_timeout sizing**: set Prometheus `scrape_timeout = 3 × walk_time`, `scrape_interval = 2 × scrape_timeout`. For a 7s walk → `scrape_timeout: 25s`, `scrape_interval: 60s`. Adding scrape_timeout as a hotfix later costs a separate PR + Prometheus reload.

Detail (full bash blocks + RTX1210/RTX830 constraint table + origin): see `~/.claude/docs/infrastructure-detail.md#physical-network-device-snmp-probe`.

## Blocked Command Boundary

When a command is blocked by any permission restriction — `sudo` required, tool-permission denied, project hook guard (e.g., mitamae dry-run guard), or user-declined approval — immediately present the blocked command prefixed with `!` so the user can run it in-session:

1. Present `! <command>` verbatim — do not add it to a "remaining tasks" list, do not describe it in prose without the `!` prefix
2. Continue with other non-blocked work in parallel while waiting for the user to run it
3. After the user runs it, verify the result before moving on

Applies equally to sudo, project-hook guards, and `deny`-listed Bash patterns.

## Auto-Mode Classifier Boundary — Production Reads vs Production Mutations

The Claude Code auto-mode classifier enforces a split during infra investigations that is independent of any prior blanket authorization: **reads** into shared/production systems (SSH probes, log tails, health-checks, `_license` / `_cluster/health` GETs) generally run inline; **persistent mutations** (license state changes, config writes, service restarts, `_license/start_basic`, a fleet `systemctl restart`) are blocked pending explicit review — even under an already-granted "実行して" / "investigate this" for the surrounding task. A go-ahead to *investigate* does not extend to a mutation discovered mid-investigation; each newly-surfaced mutation needs its own explicit authorization.

**Correct response when this fires** (accept it — do not retry the same mutating command with a workaround):

1. Finish every read-only verification step inline first (confirm the diagnosis, capture the exact before-state).
2. Present the exact mutation command (`!` per Blocked Command Boundary above, or ask plainly) — do not fold it into the read-only report as if already done.
3. Once the user authorizes **that specific action**, self-execute immediately — no further round-trip. Same shape as `git-commit.md` Merge Execution Default, generalized from `gh pr merge` to any auto-mode-classifier-blocked prod mutation.
4. Re-verify live state after the mutation (license tier, cluster health, alert/issue counts) before reporting done.

**Credential-pull sub-case**: the classifier is more likely to block a *broad* read that SSHes into a shared host and `source`s whatever env file is there to pull a secret, than a *targeted* fetch of the one credential actually needed from its owning secret store (e.g. `aws ssm get-parameter --name /monitoring/elastic/elastic-password --with-decryption --profile pve-bootstrap-ssm`, piped straight into the next command, value never echoed). Prefer the narrowest secret-fetch path — lower blast radius and less likely to trip the classifier at all.

Origin: 2026-07-11 ES license-expiry storm — classifier blocked (a) SSH+`source` into CT 112 for the elastic credential, (b) `POST _license/start_basic` after a prior blanket "実行して" covered investigation only. Read-only verify ran inline; the SSM-scoped fetch replaced SSH+source; the mutation ran only after a second, explicit "許可するから…実行して".

## systemd Timer Verification Gate

After creating or modifying a systemd timer (cookbook deploy, manual install, drop-in override), verify with `systemctl show <name>.timer --property=Trigger` — NOT `systemctl is-active <name>.timer`. A future timestamp (`Trigger: Sat 2026-05-09 08:08:21 UTC`) = the timer will fire; `Trigger: n/a` = the trigger condition cannot be evaluated and **the timer is enabled and active but will never fire** (`is-active` returns `active` either way). The usual `Trigger: n/a` cause on a `Type=oneshot` unit is `OnUnitActiveSec` on a unit whose active window is ~zero — switch to `OnUnitInactiveSec`, or add `RemainAfterExit=true`.

**Recommended `[Timer]` directives** for a drop-in self-healing oneshot: `OnBootSec=30s` (cold boot) + `OnActiveSec=30s` (covers `systemctl restart timer` after a cookbook update) + `OnUnitInactiveSec=60s` (recurring fire after first run) + `Unit=<name>.service`. The install/update `execute` MUST run all four of `daemon-reload` → `enable <name>.timer` → `restart <name>.timer` → `start <name>.service` — `enable --now` alone leaves the running timer on its old in-memory config, and `start service` seeds the `OnUnitInactiveSec` deactivation reference.

Detail (unit-file + 4-step execute examples, full `Type=oneshot` cause list, `RemainAfterExit` service-side note, origin): see `~/.claude/docs/infrastructure-detail.md#systemd-timer-verification-gate`.

## Auto-mitamae Fleet Cookbook Validation — Canary Before Fleet

When validating a cookbook fix on ONE host before fleet-wide rollout, the auto-mitamae orchestrator (driven by **cron** on the monitoring LXC — drift-checker every 2 min + orchestrator every 5 min, NOT a systemd timer) SSH-pushes `mitamae-runner`, which resets each host's `/root/setup` to `origin/main` (`git fetch + reset --hard`, detached HEAD — NOT `git pull`) and re-applies — so an unmerged fix on a feature branch is reverted within minutes. Sequence: **pause** the orchestrator (move its cron file aside on the monitoring LXC, after confirming no `mitamae-runner` is mid-run) → **apply to the canary only** (the host flagged `canary: true` in `hosts.json`) → **verify FUNCTIONALLY** (`elastic-agent status` HEALTHY + ES doc-count advancing, not `systemctl is-active`) → **merge the cookbook PR to `main` FIRST**, THEN resume (restore the cron file); resuming before merge reverts the canary too.

Detail (pause/apply/verify/resume commands incl. `pct exec` + origin): see `~/.claude/docs/infrastructure-detail.md#auto-mitamae-canary`.

## "Known Limitation" Comments Are Incomplete Fixes

When you are about to write an inline comment in a cookbook, systemd unit, or config file that admits a known gap — "manual restart required", "fires only at boot", "does not catch runtime re-injection", "only works on first boot", "will not auto-recover", or any semantic equivalent — STOP: that phrase names a **failure class** the current fix does not cover. Shipping the fix with such a comment is acceptable ONLY when BOTH (1) the uncovered class is explicitly out of scope for the current PR (stated in the PR description, not merely inferred), AND (2) a `TODO.md` entry created in the same commit names the failure class, when it triggers, and the concrete first step to close it. If neither holds, the comment is deferred design debt that silently regresses in production until someone re-investigates the same symptom. Never let "we'll get to it later" be an unstated third option.

Detail (full phrase list + action-gate procedure + origin): see `~/.claude/docs/infrastructure-detail.md#known-limitation-comments`.
