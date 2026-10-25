# Infrastructure File Guidelines

This file holds the ops rules that fire during any infra session, including read-only investigations that never open a cookbook. Long examples + origin notes are in `~/.claude/docs/infrastructure-detail.md` (NOT auto-imported — load on demand via Read tool when a section pointer matches the current task).

**Topic-specific rules** (split out 2026-05-07 to keep this file scannable):

- AWS / IAM / SSM / Terraform — see `~/.claude/docs/aws-iam.md`
- PVE LXC operational gotchas — see `~/.claude/docs/pve-lxc-detail.md`
- Docker Compose patterns — see `~/.claude/docs/docker-compose.md`
- Tailscale routing — see `~/.claude/docs/tailscale.md`

**Cookbook-authoring rules live in `infrastructure-cookbook.md`** (same directory), which loads automatically when you Read/Edit a file under `cookbooks/`, `roles/`, `pve/`, `bin/`, `config/` or a top-level `*.rb`. From another repo, Read `~/ManagedProjects/setup/.claude/rules/infrastructure-cookbook.md` by path. Sections there: Blast Radius Awareness / Config File Merge Semantics / A CLI's Active Context Is Shared Mutable State Across Cookbooks in One Apply / Commit Timing for Cookbook Changes / Cross-OS Scope Gate Before Cookbookifying a Hotfix / Per-Device Identity Probe Before Cookbook Configuration / Physical Network Device Pre-Plan SNMP Probe (YAMAHA RTX et al) / Auto-mitamae Fleet Cookbook Validation — Canary Before Fleet / "Known Limitation" Comments Are Incomplete Fixes.

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

## Incident First Response

When a user reports any service or application misbehavior (slow, unavailable, failing):
1. Run `systemctl --failed` and check OOM kills in journal before diagnosing application logic
2. Check `journalctl -u <service> -n 50 --no-pager` for the affected service
3. The cause may be OS-level, not app-level. Report findings with a concrete fix plan.

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

The classifier quotes the user's own CLAUDE.md/rules wording and AskUserQuestion label text **verbatim** as denial reasons (observed 2026-07: the kouzoh-exception line cited in a headless merge denial; a 「私」 label misread as the user). Permission-boundary rule lines are therefore runtime configuration, not documentation — the same-run reversal write-back discipline (CLAUDE.md Progress-ledger stale facts / the kouzoh line's own update clause) applies to them with production weight. See CLAUDE.md "Rule text is classifier input".

## systemd Timer Verification Gate

After creating or modifying a systemd timer (cookbook deploy, manual install, drop-in override), verify the NEXT ELAPSE — NOT `systemctl is-active <name>.timer`, which reports `active` on a timer that will never fire again. Read it with `systemctl status <name>.timer` (the `Trigger:` line — a future timestamp = armed, `n/a` = **enabled and active but will never fire**) or `systemctl list-timers <name>.timer` (`NEXT` populated vs `-`). **Do NOT use `systemctl show --property=Trigger`**: `Trigger` is not a show property at all (the show property is `Triggers`, the unit being triggered), so it prints empty for healthy and dead timers alike and makes every timer look broken. The show-level equivalents are `NextElapseUSecRealtime` for calendar schedules and `NextElapseUSecMonotonic` for `OnBootSec` / `OnActiveSec` / `OnUnit*Sec` ones — a duration means armed, `infinity` means dead.

The usual dead-timer cause on a `Type=oneshot` unit is `OnUnitActiveSec` on a unit whose active window is ~zero. Its two remedies — switch to `OnUnitInactiveSec`, or add `RemainAfterExit=true` — are **mutually exclusive**: combined, the unit parks at `active (exited)`, the deactivation `OnUnitInactiveSec` counts from never arrives, and the timer fires exactly once.

**Recommended `[Timer]` directives** for a drop-in self-healing oneshot: `OnBootSec=30s` (cold boot) + `OnActiveSec=30s` (covers `systemctl restart timer` after a cookbook update) + `OnUnitInactiveSec=60s` (recurring fire after first run) + `Unit=<name>.service`. The install/update `execute` MUST run all four of `daemon-reload` → `enable <name>.timer` → `restart <name>.timer` → `start <name>.service` — `enable --now` alone leaves the running timer on its old in-memory config, and `start service` seeds the `OnUnitInactiveSec` deactivation reference.

Detail (unit-file + 4-step execute examples, full `Type=oneshot` cause list, `RemainAfterExit` service-side note, origin): see `~/.claude/docs/infrastructure-detail.md#systemd-timer-verification-gate`.

