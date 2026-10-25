# Infrastructure File Guidelines

Ops rules for any infra session, including read-only investigations. Examples and origins: `~/.claude/docs/infrastructure-detail.md`; AWS / PVE LXC / Docker Compose / Tailscale playbooks are in the AGENTS.md Detail playbooks index. Cookbook-authoring rules (blast radius, merge semantics, cross-OS gate, canary, …) are in the path-scoped `infrastructure-cookbook.md`; from another repo Read `~/ManagedProjects/setup/.claude/rules/infrastructure-cookbook.md`.

## Managed-File Ownership Gate

Before Edit/Write of a config file under `$HOME` outside a git working tree, probe on a path fragment (a bare basename false-hits): `rg -l '<parent-dir>/<basename>' ~/ManagedProjects/setup/cookbooks/ ~/ManagedProjects/zp-SHIN/projects/mercari-setup/cookbooks/`. Hit → it is a `template` / `remote_file` target the next apply reverts; change the cookbook source (business-specific values in the private overlay). Emergency direct edit → say it "disappears on the next apply" and leave a TODO to cookbookify it in the same turn. Subsumes Dual-managed file (CLAUDE.md) and Deploy-Only Change Tracking.

**Where shared values live (first-driver ≠ owner)**: enumerate the tools that may read a value (`GITHUB_TOKEN` etc.); if 2+, it belongs in the consumer-set layer (shell `profile.d` / a generic cookbook), not the cookbook of the first tool that needed it. Detail: see `~/.claude/docs/infrastructure-detail.md#managed-file-ownership-gate`.

### Deploy-Only Change Tracking (`~/deploy/` sub-case)

For a direct change in `~/deploy/`: prefer a cookbook if one exists; otherwise make the change, immediately `ingest` what / why / path to the memory MCP, and flag it as unmanaged for future cookbookification — deploy dirs get rebuilt and untracked changes are lost.

## Commit Timing for Cookbook Changes

Always loaded (not path-scoped) because the commit it gates is a Bash call that never triggers a `paths:` rule. Dry-run passing is the commit gate: dry-run (via mitamae-validator or directly) → pass → commit immediately, don't wait for deploy or a prompt; fail → fix and retry. **No dry-run, no commit**: if the dry-run cannot run, do not commit and do not substitute lint or a config parse — report the blocker. `bin/mitamae*` is untracked, so a worktree or clone has none: run `~/ManagedProjects/setup/bin/mitamae local <recipe> --dry-run` (or `COOKBOOK=<name> … test-cookbook.rb`) from the worktree's cwd, and probe that path before claiming "mitamae is not installed".

## Incident First Response

When a user reports service misbehavior (slow, unavailable, failing): (1) `systemctl --failed` and journal OOM kills before application logic; (2) `journalctl -u <service> -n 50 --no-pager`; (3) the cause may be OS-level — report findings with a concrete fix plan.

## Blocked Command Boundary

When a command is blocked — `sudo` required, tool permission denied, a project hook guard, a `deny`-listed pattern, or user-declined approval — immediately present it verbatim as `! <command>` (not in a "remaining tasks" list or prose), continue other non-blocked work meanwhile, and verify the result after the user runs it.

## Auto-Mode Classifier Boundary — Production Reads vs Production Mutations

The auto-mode classifier splits infra work independently of any prior blanket authorization: **reads** into shared/production systems (SSH probes, log tails, health-checks, `_license` / `_cluster/health` GETs) generally run inline; **persistent mutations** (license state changes, config writes, service restarts, `_license/start_basic`, a fleet `systemctl restart`) are blocked pending explicit review — even under an already-granted "実行して" / "investigate this". A go-ahead to *investigate* does not extend to a mutation discovered mid-investigation; each newly-surfaced mutation needs its own explicit authorization.

**Correct response when this fires** (accept it — do not retry the same mutating command with a workaround):

1. Finish every read-only verification inline first (confirm the diagnosis, capture the exact before-state).
2. Present the exact mutation command (`!` per Blocked Command Boundary, or ask plainly) — never fold it into the report as if done.
3. Once the user authorizes **that specific action**, self-execute immediately — no further round-trip (the `git-commit.md` Merge Execution Default shape, generalized to any classifier-blocked prod mutation).
4. Re-verify live state after the mutation (license tier, cluster health, alert/issue counts) before reporting done.

**Credential-pull sub-case**: the classifier is more likely to block a *broad* read that SSHes into a shared host and `source`s its env file to pull a secret than a *targeted* fetch of the one credential from its owning secret store (e.g. `aws ssm get-parameter --name /monitoring/elastic/elastic-password --with-decryption --profile pve-bootstrap-ssm`, piped straight into the next command, value never echoed). Prefer the narrowest secret-fetch path.

The classifier quotes the user's own CLAUDE.md/rules wording and AskUserQuestion label text **verbatim** as denial reasons, so permission-boundary rule lines are runtime configuration, not documentation — the same-run reversal write-back discipline (CLAUDE.md Progress-ledger stale facts / the kouzoh line's own update clause) applies to them with production weight. See CLAUDE.md "Rule text is classifier input". Detail: see `~/.claude/docs/infrastructure-detail.md#auto-mode-classifier-boundary`.

## systemd Timer Verification Gate

After changing a timer, verify the NEXT ELAPSE (`systemctl status` `Trigger:` / `list-timers` `NEXT`), never `is-active` or `show --property=Trigger` (always empty). `Type=oneshot` + `OnUnitActiveSec` never fires: use `OnUnitInactiveSec` OR `RemainAfterExit=true`, never both. Install/update runs `daemon-reload` → `enable` → `restart` timer → `start` service. Detail: see `~/.claude/docs/infrastructure-detail.md#systemd-timer-verification-gate`.
