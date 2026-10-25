---
paths:
  - "cookbooks/**"
  - "roles/**"
  - "pve/**"
  - "bin/**"
  - "config/**"
  - "*.rb"
  - "test-cookbook.rb"
  - ".github/workflows/**"
---

# Infrastructure — Cookbook Authoring Rules

Path-scoped companion of `infrastructure.md` (the ops rules stay there and are always loaded). Long examples + origin notes are in `~/.claude/docs/infrastructure-detail.md`.

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

## A CLI's Active Context Is Shared Mutable State Across Cookbooks in One Apply

`gcloud`, `kubectl` and `aws` each resolve identity from an on-disk active-context file (`~/.config/gcloud/configurations/config_default`, `~/.kube/config` current-context, `AWS_PROFILE` / `~/.aws/config`). That state is **process-global and persists across cookbooks within a single mitamae run**. If an earlier cookbook sets it — `gcloud config set account`, `gcloud auth activate-service-account`, `kubectl config use-context` — every later cookbook invoking the tool WITHOUT an explicit identity flag silently runs as the new identity. The failure mode is `exit 0` with no state change, not an error.

**Rule**: any `execute` invoking one of these tools for an infrastructure operation (reading a secret, writing config, calling an API) MUST pin identity at the call site rather than inheriting whatever a sibling cookbook left active. Pin from a runtime source, not a literal, so a rename cannot silently break it:

```ruby
# metadata server gives the instance's own SA; export only when the lookup
# returns something, so a metadata-less host degrades to gcloud's own
# resolution instead of failing on an empty --account
_sa=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email 2>/dev/null || true)
[ -n "$_sa" ] && export CLOUDSDK_CORE_ACCOUNT="$_sa"
```

**Plan-phase check** — for any cookbook running after an identity-switching one in the same entry recipe's include order:

```bash
git grep -n 'gcloud ' cookbooks/*/default.rb | grep -v -- '--account\|--project\|CLOUDSDK_CORE_ACCOUNT'
git grep -n 'kubectl ' cookbooks/*/default.rb | grep -v -- '--context'
```

This is the GCP/kubectl generalisation of `~/.claude/docs/ruby-detail.md#auth-check-gate-profile` (AWS profile pinning) — same defect, different tool.

Origin: 2026-08-01 sh1-cloud — `mercari-gcloud` set the active account to the work account mid-apply; a later overlay cookbook's bare `gcloud secrets versions access` lost the instance service account its IAM grant was written for, failed with `does not have any valid credentials`, was swallowed by its own non-aborting guard, and left the cookbook a silent no-op while the run reported success. The tell was that resources NOT depending on the fetch (`known_hosts`, `config.d`) had converged normally — that split is what isolated it (zp-SHIN #114).

## Commit Timing for Cookbook Changes

After implementing a cookbook change:
1. Run mitamae dry-run (via mitamae-validator agent)
2. If dry-run passes: commit immediately — do not wait for deploy or user prompt
3. If dry-run fails: fix and retry, then commit

Dry-run passing is the commit gate for cookbook changes. Never leave cookbook changes uncommitted after a passing dry-run.

## Cross-OS Scope Gate Before Cookbookifying a Hotfix

When codifying a manual fix into a cookbook, before writing the resource block, identify the target host(s) the cookbook actually runs on and confirm the fix applies to that OS — the host where the manual hotfix worked is not always representative of every host the cookbook covers (`dpkg-divert` is Debian/Ubuntu only; `systemd-resolved`'s `resolvconf` shim is recent-Ubuntu only; AL2023 has neither). If the cookbook runs on hosts that don't satisfy the precondition, gate the resource with `only_if` (an explicit guard, not silent failure), and state the target OS in the commit message ("Ubuntu 24.04 ships ..."), not just the symptom. For scripts shipped via `remote_file` / `files/`, audit their external-command deps for macOS portability (`mitamae --dry-run` does not execute shipped scripts) — see `~/ManagedProjects/setup/.claude/rules/shell.md` "macOS External-Command Audit for Ported Linux Scripts".

Detail (5-question worked checklist + grep example + anti-pattern + origin): see `~/.claude/docs/infrastructure-detail.md#cross-os-scope-gate`.

## Per-Device Identity Probe Before Cookbook Configuration

Before writing any cookbook resource that keys off a host's identity — hostname match in a device registry (`devices.json`, `node_map`, YAML host dict), user-home path, SSH login user, or per-device SSM parameter name — SSH-probe the actual target host for `hostname -s`, `scutil --get HostName`, `whoami`, and `$HOME`. The three values that diverge from cookbook assumptions most often: `hostname -s` (macOS factories set a hardware serial before a friendly name), `whoami` (work-issued Macs use a different admin account, e.g. `sh1` vs `shin1ohno`), and `$HOME` (root's home varies by LXC template). Never write a `node[:hostname]` match or `ssh_user` field from memory or old docs — use what the probe reports; if a host's conceptual name diverges from `hostname -s`, add an explicit override field (`hostname`, `aliases`) and document the divergence in the entry.

Detail (probe one-liner + 3 divergence examples + origin): see `~/.claude/docs/infrastructure-detail.md#per-device-identity-probe`.

## Physical Network Device Pre-Plan SNMP Probe (YAMAHA RTX et al)

Before writing any terraform resource for a CLI-driven physical network device (YAMAHA RTX, Cisco, Juniper), the firmware imposes constraints invisible to the terraform provider's plan output. Surface them at plan phase via SSH probe, not after `terraform apply` — each unprobed constraint typically costs one PR cycle. Probe once per device family (capture outputs in the plan file): (1) firmware revision, (2) SNMP version reachability (RTX1210 Rev.14.01.42 silently drops v2c), (3) ifTable vs ifXTable (0 ifXTable rows → no 64-bit counters; use 32-bit `ifInOctets` / `ifOutOctets`), (4) SNMP walk duration, (5) existing SNMP config (community-length / syslocation-token constraints).

**Scrape_timeout sizing**: set Prometheus `scrape_timeout = 3 × walk_time`, `scrape_interval = 2 × scrape_timeout`. For a 7s walk → `scrape_timeout: 25s`, `scrape_interval: 60s`. Adding scrape_timeout as a hotfix later costs a separate PR + Prometheus reload.

Detail (full bash blocks + RTX1210/RTX830 constraint table + origin): see `~/.claude/docs/infrastructure-detail.md#physical-network-device-snmp-probe`.

**Cutover safety**: when the change reconfigures a LIVE device's interface roles / bridge membership / addressing / admin access (not just adds monitoring), run the cutover-safety checklist BEFORE the work — (1) boot-source check (`show environment` 実行中設定ファイル; inserted recovery USB boots its stale config on EVERY restart while `save` writes internal CONFIG0), (2) deadman restart + staged save (batch unsaved, `save` only after basic-connectivity verification), (3) explicit reboot after bridge/L2-membership changes (fe80 link-locals are NOT regenerated at runtime — interface stays v6-down with correct config), (4) single-command firmware-acceptance canary in admin mode before `terraform apply` (schema validation ≠ firmware acceptance), (5) mirror≠evidence (a source chain's permissive fallback can mask placement bugs — verify mechanism, not placement). Detail + origin (2026-08-12 HND loopback cutover: 2 rollbacks + 1 shipped filter bug): see `~/.claude/docs/infrastructure-detail.md#physical-network-device-cutover-safety`.

## Auto-mitamae Fleet Cookbook Validation — Canary Before Fleet

When validating a cookbook fix on ONE host before fleet-wide rollout, the auto-mitamae orchestrator (driven by **cron** on the monitoring LXC — drift-checker every 2 min + orchestrator every 5 min, NOT a systemd timer) SSH-pushes `mitamae-runner`, which resets each host's `/root/setup` to `origin/main` (`git fetch + reset --hard`, detached HEAD — NOT `git pull`) and re-applies — so an unmerged fix on a feature branch is reverted within minutes. Sequence: **pause** the orchestrator (move its cron file aside on the monitoring LXC, after confirming no `mitamae-runner` is mid-run) → **apply to the canary only** (the host flagged `canary: true` in `hosts.json`) → **verify FUNCTIONALLY** (`elastic-agent status` HEALTHY + ES doc-count advancing, not `systemctl is-active`) → **merge the cookbook PR to `main` FIRST**, THEN resume (restore the cron file); resuming before merge reverts the canary too.

Detail (pause/apply/verify/resume commands incl. `pct exec` + origin): see `~/.claude/docs/infrastructure-detail.md#auto-mitamae-canary`.

## "Known Limitation" Comments Are Incomplete Fixes

When you are about to write an inline comment in a cookbook, systemd unit, or config file that admits a known gap — "manual restart required", "fires only at boot", "does not catch runtime re-injection", "only works on first boot", "will not auto-recover", or any semantic equivalent — STOP: that phrase names a **failure class** the current fix does not cover. Shipping the fix with such a comment is acceptable ONLY when BOTH (1) the uncovered class is explicitly out of scope for the current PR (stated in the PR description, not merely inferred), AND (2) a `TODO.md` entry created in the same commit names the failure class, when it triggers, and the concrete first step to close it. If neither holds, the comment is deferred design debt that silently regresses in production until someone re-investigates the same symptom. Never let "we'll get to it later" be an unstated third option.

Detail (full phrase list + action-gate procedure + origin): see `~/.claude/docs/infrastructure-detail.md#known-limitation-comments`.
