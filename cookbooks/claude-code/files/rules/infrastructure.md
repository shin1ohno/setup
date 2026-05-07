---
globs: ["*.yaml", "*.yml", "*.tf", "Dockerfile", "docker-compose*.yml"]
---

# Infrastructure File Guidelines

- Always verify changes with dry-run / plan before applying
- Never hardcode secrets, tokens, or passwords — use environment variables or secret management
- Validate YAML/HCL syntax before committing
- Document non-obvious configuration choices with comments

## Blast Radius Awareness

When modifying infrastructure, always evaluate whether the change triggers resource recreation or just in-place update.

- **Before adding logic to a provisioning script** (user_data, cloud-init, etc.): check whether that script's content hash feeds into a replace trigger. If it does, the change will destroy and recreate the resource
- **Separate base infrastructure from application deployment**: OS setup, networking, and runtime installation belong in provisioning (runs at resource creation). Application code, configs, and container orchestration belong in a deploy step that can run independently without recreating the resource
- **Never mix change frequencies**: a file that changes weekly (app config) must not share a content hash with a file that should change rarely (OS bootstrap). If they are hashed together, the fast-changing file forces recreation of the slow-changing resource
- **When fixing a bug on a running instance**: determine whether the fix belongs in the base provisioning layer or the application deploy layer. Defaulting to the provisioning script because "it's already there" creates coupling that causes unnecessary recreation later

## Perpetual Drift Decision Framework

`terraform plan` showing the same attribute diff on every run — especially one marked `forces replacement` — is not a one-off glitch; it is perpetual drift. Every apply replaces real resources to chase a cosmetic discrepancy. The 2026-04-22 incident session cascaded through 4 EC2 generations this way before the root cause was fixed.

**Trigger**: when the same diff survives a successful apply (run `terraform plan` again immediately — same attribute still shows), treat it as perpetual drift and pick a fix *before* the next apply. Do not accept "one more apply will clear it" for the third time.

**Decision flow** — pick in this order of preference; `ignore_changes` is last resort, not first reach:

- **A. Redesign away the pressure point** — if the forcing attribute is load-bearing for the architecture (e.g., instance in a public subnet with EIP, while Tailscale would be equally happy in a private subnet behind NAT), reconsider whether the resource belongs where it is. Most expensive change, but leaves nothing to fight later
- **B. Suppress the drift at its source** — if the drifting attribute is inherited from a parent resource setting (subnet `map_public_ip_on_launch`, VPC-level defaults, launch-template defaults), change that parent setting if only this resource uses it. Cheapest root-cause fix when the parent is scoped to the consumer
- **C. Match reality in the config** — if the attribute's actual value is harmless and intentional at the AWS level, update the Terraform config to match it. state == reality, no ignore list. Pays one replacement cost up front; free after that
- **D. `lifecycle.ignore_changes = [attr]`** — only when the attribute is purely cosmetic and A/B/C are disproportionate to the noise. Leaves a permanent state-vs-reality gap; always accompanied by an inline comment explaining *why* Terraform should stop reconciling this attribute

**Trap**: D looks the cheapest so it attracts first. It also hides future *real* drift on the same attribute (e.g., AWS deprecates the auto-assign default; you never see it). Prefer A/B/C unless the scope genuinely forbids them.

**Commit-message guidance for D**: name the parent setting that forces the drift (e.g., "aws_subnet.c_public has map_public_ip_on_launch=true"), not just the symptom. The next reader needs to know which of A/B/C was rejected and why.

### Common AWS cosmetic-drift attributes

Check here before declaring a novel case. Each entry names the **parent setting** that forces the drift, which dictates which of A/B/C applies.

- `aws_instance.associate_public_ip_address` — forced by `aws_subnet.map_public_ip_on_launch=true` on the instance's subnet. Real public address typically comes from an `aws_eip_association`. The auto-assigned IP is replaced by the EIP at association time and is cosmetically gone; Terraform still sees the attribute
- `aws_instance.tags` ordering or case — normally provider-resolved, but AWS tag policies / Organization-level tag enforcement can silently rewrite case or inject tags
- `aws_iam_role` / `aws_iam_instance_profile` — references may drift between `arn` and `name` forms across provider major versions; lock to one form
- `aws_route53_record.ttl` — drifts when a record is managed by an external system (e.g., CDN auto-TTL)
- `aws_s3_bucket` sub-resources — historically many attributes moved out of the main block into dedicated resources (`aws_s3_bucket_versioning`, etc.); legacy configs drift until the dedicated resource is adopted
- `aws_security_group.ingress` / `egress` rule ordering when mixed with `aws_security_group_rule` resources — never mix inline and separate rule resources on the same SG

Add a row when a new cosmetic-drift case is fixed. Each row must be actionable: name the parent setting and which decision-flow option was chosen.

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

**Before adding to a cookbook, answer**:

1. Which repo owns this fix? List the candidate repos (`setup` for personal Linux/macOS, `home-monitor` for AWS EC2, `edge-agent` for embedded targets, etc.). Don't default to "wherever I saw the manual fix" — pick the cookbook whose target hosts have the failing condition
2. What OS / package manager / init system does the failing condition require? `dpkg-divert` is Debian/Ubuntu only. `systemd-resolved` shipping a `resolvconf` shim is recent Ubuntu only. Amazon Linux 2023 doesn't have either
3. Does the cookbook run on hosts that don't satisfy the precondition? If yes, gate the resource with `only_if` so it skips on non-matching hosts. Don't rely on the resource silently failing — write an explicit guard
4. State the target OS in the commit message ("Ubuntu 24.04 ships ..."), not just the symptom

**Anti-pattern**: discovering a Linux-specific fix on `pro` and adding it unguarded into a cookbook that also runs on macOS or AL2023. The wrong-OS branches will either silently no-op (best case) or fail loudly on every dry-run (worse case, blocks unrelated work).

This rule exists because the 2026-04-26 session correctly identified that the `dpkg-divert` fix belonged in `setup/cookbooks/tailscale/` (Ubuntu hosts), not `home-monitor/scripts/tailscale_setup.sh` (Amazon Linux 2023 EC2). The decision was sound — codifying the pattern so the OS-scope question is asked before, not after, picking a destination.

## Long-Running Operations

`terraform plan`, `terraform apply`, and other commands that typically take 30+ seconds must run in a background sub-agent (`run_in_background: true`) so the main conversation remains interactive. Pattern:

1. Launch a background agent that runs the command and parses the output
2. Continue interacting with the user (answer questions, start other work)
3. When the agent completes, present the results and ask for next steps

This applies to: `terraform plan/apply`, `docker build`, long test suites, and any command where the user cannot usefully intervene mid-execution.

## Docker Compose Branch-Dep Pre-Deploy Check

Before running `docker compose up -d --build` (with or without a service argument) from a feature branch, verify the branch's base is up-to-date with every sibling feature already merged to `origin/main`.

```
git fetch origin
git log origin/main..HEAD --oneline
```

If the working tree's branch was cut from `origin/main` *before* a sibling feature PR merged, the working tree contains pre-merge code for any shared service. `docker compose up -d --build <service>` rebuilds the named service from that pre-merge code, **and** rebuilds any sibling service whose Dockerfile context has changed relative to the branch's base — which silently regresses the sibling feature's deployed state.

**Safe pattern** when stacking work:

1. `git fetch origin && git merge origin/main` — pull merged sibling features into the working branch first
2. `cargo build` / `npm run build` to confirm the merge compiles cleanly
3. `docker compose up -d --build <service>` for the deploy

**Anti-pattern**: running `docker compose up -d --build weave-web` from a feature branch that diverged from `origin/main` two PRs ago. The compose run will rebuild `weave-server` too if its working tree has any change relative to the branch base — and the rebuild produces a **regressed** weave-server image because the branch lacks the parent PRs' server-side commits.

This rule exists because the 2026-04-27 cross-edge intent forwarding session deployed weave-web from a feature branch cut from `origin/main` while PR #51 (cross-edge server logic) was still open. The compose rebuild produced a weave-server image without PR #51's `find_edge_for_service` and `EdgeToServer::DispatchIntent` arm, immediately regressing Hue / Roon dispatch. Recovery required merging PR #51, merging `origin/main` into the working branch, and rebuilding weave-server again — costing two extra deploy cycles.

## Terraform Apply Branch Gate

Before invoking `terraform apply`, run `git branch --show-current` and confirm the branch is `main` (or the repo's designated deploy branch). If on a feature branch, stop and present the apply as a user-run command:

```
! cd /absolute/path/to/repo && terraform apply -target=<scope>
```

Do NOT attempt `terraform apply` from a feature branch — permission gates often deny this anyway, and applying unmerged changes bypasses the review gate. The correct sequence is: PR merge → pull `main` → apply. The PR's `terraform plan` output is the pre-apply review artifact; the post-merge apply is just the execution step.

This rule exists because the 2026-04-25 session attempted `terraform apply` from an unmerged feature branch in home-monitor; the permission layer correctly denied it, surfacing that the proper flow is merge-first-then-apply.

## AWS SSM Parameter Path Constraints

Before writing any `aws_ssm_parameter` Terraform resource or `aws ssm put-parameter` cookbook call, validate the planned path is not in a reserved namespace. AWS blocks any path starting with `/aws` or `/AWS` at the API level (`AccessDeniedException: No access to reserved parameter name: ...`) — the error fires at apply time, not at plan time, and Terraform does not surface it as a plan diff.

**Pre-plan probe** (run in the target account before writing the resource):

```bash
# A PUT + immediate DELETE confirms the path is writable.
# Cost: creates and destroys a dummy param.
AWS_PROFILE=<profile> aws ssm put-parameter \
  --name "/your-planned-prefix/probe" \
  --value "probe" --type String \
  --overwrite --region <region> 2>&1 && \
AWS_PROFILE=<profile> aws ssm delete-parameter \
  --name "/your-planned-prefix/probe" \
  --region <region>
```

Reserved prefixes that fail at apply (not plan):

- `/aws/`, `/aws-` (e.g. `/aws-keys/...` — looks reasonable but rejected)
- `/AWS/`, `/AWS-`
- `/ssm/` (also reserved)

Prefer project-scoped prefixes (`/<project>/<purpose>/...`, e.g. `/home-monitor/iam/<user>/<key-name>`) to avoid the entire class.

This rule exists because home-monitor PR #12 (2026-05-06) created `aws_ssm_parameter` resources at `/aws-keys/pve-bootstrap-ssm/{access-key-id,secret-access-key}` — `terraform plan` was clean (5 to add) and `terraform apply` succeeded for the IAM user / access key / policy resources but failed both `aws_ssm_parameter` puts with `AccessDeniedException: No access to reserved parameter name: aws-keys/pve-bootstrap-ssm/access-key-id`. Hotfix PR #14 renamed to `/home-monitor/iam/pve-bootstrap-ssm/...` and the same plan re-applied cleanly. The pre-plan probe takes 5 seconds and would have caught the rejection before the IAM user was created in a half-applied state.

## Per-Device Identity Probe Before Cookbook Configuration

Before writing any cookbook resource that keys off a host's identity — hostname match in a device registry (`devices.json`, `node_map`, YAML host dict), user-home path, SSH login user, or per-device SSM parameter name — run a one-shot probe on the actual target host to confirm the values your cookbook will use:

```bash
ssh <target> 'echo "hostname-s: $(hostname -s)"; echo "scutil HostName: $(scutil --get HostName 2>/dev/null)"; echo "user: $(whoami)"; echo "home: $HOME"'
```

Three values that diverge from cookbook assumptions most often:

1. **`hostname -s`** — macOS factories set this to a hardware serial (e.g. `XMHTM6QVQX`) before the user gives the machine a friendly name in System Settings. `scutil --get ComputerName` returns the friendly name but mitamae's `hostname -s` runs the BSD utility and gets the unmodified short hostname.
2. **`whoami`** — admin accounts on shared machines or work-issued Macs may differ from the personal username assumed in the cookbook (e.g., `sh1` vs `shin1ohno`).
3. **`$HOME`** — on some LXC templates, `root` has `HOME=/` or `HOME=/root` depending on whether the template populated `/etc/passwd` for the UID.

Never write a `node[:hostname]` match expression or `ssh_user` field from memory or earlier documentation — SSH-probe the host and use what it actually reports. If devices.json (or equivalent) needs to track a host whose conceptual name diverges from `hostname -s`, add an explicit override field (`hostname`, `aliases`, etc.) and document the divergence in the entry.

This rule exists because setup PR #142 (2026-05-06) was required after `air`'s ssh-keys cookbook silently skipped its run (`hostname '<serial>' not in devices.json, skipping`). devices.json had `name: "air"` (= old conceptual name) + `ssh_user: "shin1ohno"` (= the user's other-machine convention), but the actual Mac reported `hostname -s = XMHTM6QVQX` (factory serial) + `whoami = sh1`. Both mismatches were invisible until per-device verification surfaced them. A 2-second probe at the start of Phase 2 per-device work would have caught both before any cookbook code was written.

## Incident First Response

When a user reports any service or application misbehavior (slow, unavailable, failing):
1. Run `systemctl --failed` and check OOM kills in journal before diagnosing application logic
2. Check `journalctl -u <service> -n 50 --no-pager` for the affected service
3. Report findings **with a concrete fix plan** for review — never present findings alone without actionable next steps. The cause may be OS-level, not app-level

## Blocked Command Boundary

When a command is blocked by any permission restriction — `sudo` required, tool-permission denied, project hook guard (e.g., mitamae dry-run guard), or user-declined approval — immediately present the blocked command prefixed with `!` so the user can run it in-session:

1. Present `! <command>` verbatim — do not add it to a "remaining tasks" list, do not describe it in prose without the `!` prefix
2. Continue with other non-blocked work in parallel while waiting for the user to run it
3. After the user runs it, verify the result before moving on

Applies equally to sudo, project-hook guards, and `deny`-listed Bash patterns.

## Container state path audit when `user:` is non-root

When designing or reviewing a `docker-compose` service that:

1. Runs as a non-root UID (`user: "1000:1000"`, `user: "${UID}:${GID}"`, or any explicit non-zero UID)
2. AND persists state via a path derived from `$HOME` or any `XDG_*` environment variable (Rust `dirs_next::config_dir()`, Python `appdirs`, Go `os.UserConfigDir`, Node `os.homedir()`, etc.)
3. AND has a bind-mount intended to receive that state on the host

…audit explicitly what `$HOME` resolves to **inside the container** before the mount is wired. Three traps in sequence:

**Trap 1 — `HOME=/`**: Many minimal base images (`alpine`, `debian:bookworm-slim`, distroless variants) do not set `HOME` for non-root UIDs that lack a `useradd` entry. The process inherits `HOME=/` from the docker init env. `dirs_next::config_dir()` returns `/.config`, which a non-root UID cannot create or write under.

**Trap 2 — mount destination unreachable from the resolved path**: Even when the host bind-mount lands at `/root/.config/roon-rs` (the cookbook's `home` interpolation), the application uses `/.config/...` not `/root/.config/...` — so the mount catches zero writes. The state is silently written to the container's writable layer (or fails) and lost on restart.

**Trap 3 — `/root` mode 700**: If `HOME=/root` is set but the running UID is not 0, the default image `/root` mode 700 root:root blocks traversal. `Permission denied` even when the deeper directory is correctly chowned.

**Audit checklist** before merging the cookbook / compose change:

1. `docker exec <c> sh -c 'id; env | grep -E HOME=|XDG_'` — confirm running UID and what `HOME` / `XDG_*` resolve to
2. `docker exec <c> sh -c 'ls -ld / /root /home 2>&1'` — confirm traversability for the running UID
3. Choose ONE of:
   - Set `XDG_CONFIG_HOME` (or the language-specific equivalent) explicitly in the `environment:` block to a path **inside the bind-mount**, e.g. `XDG_CONFIG_HOME: /data` + mount `/var/lib/<service>:/data:rw`
   - OR set `HOME` explicitly to a path you know is mounted and traversable for the running UID
   - OR add a Dockerfile `USER <name>` directive that creates a real home directory at image build time
4. Verify with `docker exec <c> sh -c 'echo probe > $XDG_CONFIG_HOME/probe && rm $XDG_CONFIG_HOME/probe'` after deploy

Prefer option (a) `XDG_CONFIG_HOME` override + system-standard `/var/lib/<service>/`: it's traversable by any UID by default (mode 755 root:root inherited from `/var`), system-conventional, and decouples the host path from any home-directory ambiguity. Avoid `/root/...` for non-root containers entirely.

**Codify in the cookbook**:

```ruby
# State directory tree owned by container UID (matches compose `user:` directive).
# /var/lib/<service>/ is system-standard and traversable; /root/... is unsafe
# for non-root containers because the default image /root mode is 700 root:root.
state_dir = "/var/lib/<service>/state"

directory state_dir do
  owner "1000"   # MUST be String per ~/.claude/rules/ruby.md
  group "1000"
  mode "755"
end
```

```yaml
# compose
environment:
  XDG_CONFIG_HOME: "/data"
volumes:
  - /var/lib/<service>/state:/data:rw
```

This rule exists because lxc-roon-mcp cookbook (PR #131, 2026-05-05) initially mounted `${home}/.config/roon-rs:/root/.config/roon-rs:rw` while the container ran as UID 1000 with `HOME=/`. The application wrote to `/.config/roon-rs/` (unwritable for UID 1000), the bind-mount caught zero writes, and `roon_api::registry: Failed to persist token: Permission denied (os error 13)` warns repeated on every Roon Core handshake. Fixed by switching to `/var/lib/roon-mcp/state` host path + `XDG_CONFIG_HOME=/data` env. The audit checklist would have caught this at plan time.

## Stale Terraform State Lock Recovery

When `terraform plan` or `terraform apply` aborts with `Error acquiring the state lock`, the previous run left a DynamoDB lock that was not released (process killed, network drop, container shutdown). Recovery:

1. Read the lock ID from the error block (`ID: a845a182-6011-acf6-e431-005ee971d1c5`)
2. Confirm no other apply is in flight — check background sub-agents (`TaskList`), other terminals on the same host, and the lock's `Who` / `Created` fields in the error to gauge age
3. `terraform force-unlock -force <lock-id>`
4. Re-run the original command

Never `force-unlock` while another apply may legitimately hold the lock — overlapping writes corrupt state. Stale locks more than ~10 min old with no visible apply process are safe to break.

This rule exists because the 2026-05-04 PVE-migration session inherited a 14-hour-old lock from a yesterday-aborted apply; rediscovering the `force-unlock` path cost time. The lock's `Who: shin1ohno@pro-dev` field made it identifiable as a self-orphan.

## Tailscale `accept-routes=true` + Kernel Policy Routing Conflict

When a host enables `tailscale set --accept-routes=true` while also serving as a LAN router or gateway, Tailscale injects peer-advertised routes into kernel **routing table 52**, selected by `ip rule 5270: from all lookup 52` — which is consulted **before** the main table. If any tailnet peer advertises a supernet that overlaps with the host's own LAN CIDR (classic example: `hnd-subnet-router` advertises `192.168.0.0/16` while the host's eth0 is on `192.168.1.0/24`), every reply from the host to a LAN address gets routed via `tailscale0` instead of `eth0`. Local connectivity silently breaks; SSH from LAN, intra-LAN HTTP probes, and reverse-proxy upstream reachability all start timing out.

Diagnosis:

```
ip rule show           # confirm `5270: from all lookup 52` is present
ip route show table 52 # see which peer routes Tailscale injected
```

Fix: drop the conflicting supernet from table 52 (and from main, if also present):

```
ip route del <conflicting-cidr> dev tailscale0 table 52 || true
ip route del <conflicting-cidr> dev tailscale0 || true
```

Codify in a oneshot systemd unit so the cleanup re-runs on every tailscaled restart / LXC reboot. Reference cookbook: `cookbooks/lxc-pro-router/default.rb` (PR #115, 2026-05-04). The remaining peer routes (`10.33.128.0/18` for AWS VPC, `100.64.0.0/10` for tailnet CGNAT) are safe to keep — only LAN supernets cause the conflict.

Detection signal: LAN reachability to the Tailscale router host suddenly drops the moment `accept-routes=true` is set, even though all other Tailscale functionality (subnet advertise, peer ping) keeps working. The asymmetry is the tell.

## Short-lived STS Token Refresh Before Multi-Host mitamae Apply

`aws-login` / `aws sso login` issues STS tokens with 15-60 minute lifetimes. A multi-LXC mitamae batch (8+ hosts in sequence with image pulls) can outlast a freshly-fetched token. Tokens that were `scp`'d to LXC nodes go stale **independently** of the local copy — even if `aws sts get-caller-identity` still works on the orchestrator, the LXC's `~/.aws/credentials` may already be expired.

Pre-batch checklist:

1. `aws sts get-caller-identity --profile <profile>` immediately before launching the batch — confirms the local token is valid
2. If credentials are SCP'd to LXCs: re-SCP after every refresh; do not assume the local-side validity propagates
3. For batches expected to take >10 min: refresh + re-SCP at the start AND set a wakeup to re-check at half the token lifetime
4. Prefer **IAM instance profiles** on LXCs (or workload-identity equivalents) over SCP'd temporary credentials — instance profiles auto-rotate via IMDS and never need re-SCP

This rule exists because the 2026-05-04 PVE-migration session burned 4 separate refresh-and-re-SCP cycles when the token expired mid-batch. Each cycle required pausing apply, re-fetching, re-distributing, then resuming — a ~3-min loss per cycle that is fully preventable by pre-batch validation + instance profiles for steady-state.

## PVE LXC — Bind Mounts and `terraform import`

`mount_point` blocks with `volume = "/<host-path>"` (which PVE treats as `type = bind`) **cannot be created via the bpg/proxmox provider when authenticating with an API token**, regardless of the token's role (PVEAdmin included). PVE's source-level check is literal:

```perl
# from PVE/LXC/Config.pm
if ($mp->{type} eq 'bind' && $authuser ne 'root@pam') {
    die "mount point type bind is only allowed for root\@pam\n";
}
```

The check uses string equality on `$authuser`, so `root@pam!terraform` (a token of root@pam) does NOT pass. This trap is invisible at plan time because existing bind-mounted LXCs (cognee/weave/memory) are in TF state — their `terraform plan` output is clean — but they entered state via `pct create` on the PVE host as root@pam followed by `terraform import`, NOT via TF-managed creation.

**Workflow for a new LXC with bind mounts**:

1. Build the `pct create` command from the TF spec (cores, memory, disk, network, mounts, features.nesting, unprivileged, startup, ssh-public-keys, password). Use `pct config <existing-similar>` as a reference template.
2. Run on PVE host as root@pam: `pct create <vmid> <template> <flags...>`
3. `pct set <vmid> --startup order=N,up=M,down=K` separately — the `--startup` flag during `pct create` silently doesn't take effect (bpg/proxmox quirk; verified by inspecting `pct config` post-create).
4. `terraform import 'proxmox_virtual_environment_container.lxc["<name>"]' <node>/<vmid>` — the import address format for bpg/proxmox is **`<node>/<vmid>`** (e.g. `pro/111`), not bare `vmid`.
5. Run `terraform plan`. The plan WILL show `forces replacement` on `initialization` (write-only `user_account.{keys,password}`) and `operating_system.template_file_id` (PVE doesn't expose the post-extract template path via API). This is permanent drift; the post-import LXC cannot be reconciled in-place.
6. **Add `lifecycle { ignore_changes = [initialization, operating_system, mount_point] }`** to the for_each container resource (or to the specific resource if not in for_each). Document with a comment naming the three drift sources.
7. Re-plan: should now show only the IAM/SSM/network adds + an in-place update for `start_on_boot` / `started`. No destroys.

**State-archaeology check before designing**: if the new LXC needs a bind mount, run `terraform state show 'proxmox_virtual_environment_container.lxc["<existing-with-bind-mount>"]'` first. The presence of the bind mount in state with no plan diff confirms the manual-create + import convention is the established path. Do NOT default to "let TF create it" — the API token's permission ceiling makes this fail at apply time, costing one or more apply-retry cycles.

This rule exists because the 2026-05-06 PR #15 (home-monitor monitoring LXC) terraform apply failed twice on `mount point type bind is only allowed for root@pam` before the API-token-vs-root@pam constraint was confirmed by reading PVE source. Recovery required a hotfix PR (#17) adding `lifecycle.ignore_changes`, plus manual `pct create 111` + `terraform import pro/111`. The full sequence cost ~45 min that would have collapsed to ~5 min if the state-archaeology check at plan time had surfaced the convention.

## Unprivileged LXC Bind-Mount Host Ownership Mapping

In an unprivileged PVE LXC, container UID/GID are mapped to a high host range (default offset **100000**, so container UID 0 = host UID 100000, container UID 1000 = host UID 101000, container UID 65534 = host UID 165534, etc.). Host directories used as bind-mount targets must be owned by the host UID that maps to the in-container UID the cookbook expects.

**The trap**: a cookbook resource

```ruby
directory "/data/<service>" do
  owner "root"
  group "root"
end
```

will fail at converge time with `chown: changing ownership of '/data/<service>': Operation not permitted` when:

1. The container is unprivileged.
2. `/data/<service>` is a bind mount of a host directory (e.g. `/mnt/data/<service>`).
3. The host directory's owner does NOT map to UID 0 inside the container.

The cookbook's `chown` runs inside the container as in-namespace root. In-namespace root has CAP_CHOWN over files owned by *mapped* UIDs (100000–165535 by default). It cannot chown files owned by host UIDs **outside** that range — including host root (UID 0), which maps to nobody (UID 65534) inside the container.

**Pre-bootstrap step on the PVE host** (run once per new bind mount, as root@pam):

```bash
mkdir -p /mnt/data/<service>
chown 100000:100000 /mnt/data/<service>   # container root
chmod 755 /mnt/data/<service>
```

This makes the directory appear as `root:root` (UID 0) inside the container, so the cookbook's `directory ... owner "root"` resource is a no-op (no chown attempt).

**Subdirectories for non-root container processes**: services like Prometheus (runtime UID 65534 / `nobody`) and Grafana (runtime UID 472 / `grafana`) need their data subdirectories owned by their respective container UIDs. The cookbook can create the subdirectory and chown to those UIDs inside the container (in-namespace root has CAP_CHOWN over UIDs in the mapped range, which covers 0–65535 inside ↔ 100000–165535 on host). Example:

```ruby
# Inside the container, these UIDs map cleanly to host UIDs 165534 and 100472.
directory "/data/<service>/prometheus" do
  owner "65534"   # nobody (Prometheus runtime user)
  group "65534"
  mode "755"
end

directory "/data/<service>/grafana" do
  owner "472"     # grafana runtime user
  group "472"
  mode "755"
end
```

If the cookbook omits explicit owners for subdirectories, the bind-mount target ends up `root:root` inside the container, and the docker container processes (running as non-root) crash-loop with `Permission denied` on first write — visible in `docker logs <container>` but invisible to mitamae which already declared the directory resource "successful".

**Detection signal**: docker container restarting on an unprivileged-LXC bind-mount with logs showing `Permission denied` / `mkdir: ... not writable` → host directory owner doesn't match the container runtime UID. Fix path: chown the bind-mount subdirectory inside the container (`pct exec <vmid> -- chown -R <runtime-uid>:<runtime-uid> /data/<service>/<subdir>`) then `docker compose restart`.

This rule exists because the 2026-05-06 monitoring CT 111 first mitamae apply created `/data/monitoring/{prometheus,grafana}` as `root:root` inside the container; both Prometheus (UID 65534) and Grafana (UID 472) crash-looped on first write. Recovery: in-container chown to the correct runtime UIDs, then `docker compose restart`. Plan time should have included an explicit `directory` resource per service subdirectory with the runtime UID. Dry-run on the dev box hides this because the dev box is privileged Linux without UID mapping.

## docker-compose Notify-Driven Restart Requires `--force-recreate`

Cookbook `execute` resources that restart a docker-compose stack via `notifies :run` (action `:nothing`, fired when a `remote_file` content changes) MUST run `docker compose up -d --force-recreate`. Plain `up -d` is a **no-op** when the image digest and compose spec are unchanged — it does not detect bind-mount file content changes, so the cookbook's "config edited" notify silently leaves the running container serving the old config until a manual `docker restart`.

```ruby
# WRONG — config edits silently ignored on already-running containers
execute "restart <service>" do
  command "docker compose -f #{compose_path} up -d"
  user user
  action :nothing
end

# RIGHT — recreates the container so bind-mounted config edits take effect
execute "restart <service>" do
  command "docker compose -f #{compose_path} up -d --force-recreate"
  user user
  action :nothing
end
```

**`ensure X running`** (initial-state) executes are intentionally NOT touched. Their `only_if` shell guards already short-circuit when the desired services are running, so re-creating them every mitamae run would regress idempotency. The notify-driven path is the correct boundary for `--force-recreate`: it fires exactly when a cookbook-managed config file changed.

**Detection signal**: `mitamae apply` reports success after a `remote_file` config change, but `docker exec <container> cat /etc/<service>/config.yml` (or equivalent) still shows the old content. Or: the running daemon's `/api/v1/status/config` endpoint reports stale settings. Or: `docker ps --format '{{.Names}}: {{.RunningFor}}'` shows uptime older than the latest config edit.

**Detection grep** when reviewing a docker-compose-deploying cookbook:

```
git grep -B3 'action :nothing' cookbooks/ | grep -A2 'execute "(docker compose )?restart' | grep 'docker compose .* up -d' | grep -v 'force-recreate'
```

Any hit is a candidate.

This rule exists because the 2026-05-06 Phase 2b verify session shipped PR #154 (`prometheus.yml: honor_labels: true`), and the cookbook's `restart monitoring` notify fired correctly — but the bare `up -d` was a no-op, so the running prometheus container kept the pre-edit config until manual `docker kill --signal=SIGHUP`. Recovery swept 7 cookbooks (PRs #158 + #159) to add `--force-recreate` to the notify-driven paths: ai-memory, cognee, hydra, lxc-consent, lxc-monitoring, lxc-roon-mcp, lxc-weave.

## Grafana Datasource Provisioning — Pin `uid` Explicitly

Every Grafana datasource declared via provisioning YAML (`/etc/grafana/provisioning/datasources/*.yml`) MUST include an explicit `uid:` field. Without it, Grafana auto-generates a random uid (e.g. `PBFA97CFB590B2093`) at first container boot. Dashboard JSON checked into the cookbook references the datasource via `"uid": "<slug>"` — if those refs don't match the auto-generated uid, every panel renders **"No data"** despite the underlying Prometheus query returning valid results.

```yaml
# WRONG — Grafana auto-generates a random uid; dashboard JSON refs fail
datasources:
  - name: Prometheus
    type: prometheus
    url: http://prometheus:9090
    isDefault: true

# RIGHT — pin a stable lowercase slug matching the dashboard JSON
datasources:
  - name: Prometheus
    uid: prometheus       # ← matches "uid": "prometheus" in dashboards/*.json
    type: prometheus
    url: http://prometheus:9090
    isDefault: true
```

**The diagnostic path is expensive** because the visible symptoms point AWAY from the actual cause:

- Prometheus `/api/v1/query` returns valid metrics ✓
- Prometheus targets are UP ✓
- Grafana healthcheck returns OK ✓
- Dashboard JSON loads correctly (no parse error) ✓
- Every panel shows "No data" ✗

The only way to diagnose without this rule is to manually inspect `GET /api/datasources` for the actual uid, compare against the dashboard JSON's `"uid"` ref, and notice the mismatch. Worth ~15 minutes per incident.

**Detection signal**: a dashboard with valid PromQL queries showing "No data" across all panels. Compare `curl -u admin:<pw> http://<grafana>/api/datasources | jq '.[].uid'` against `grep -hoE '"uid":[^,]+' /path/to/dashboards/*.json | sort -u`.

After fixing the provisioning yaml, **`docker compose restart grafana`** is required (or full container recreate) — Grafana reloads provisioned datasources on container start, not on file watch.

This rule exists because the 2026-05-06 Phase 2b verify session shipped a Grafana auto-mitamae-fleet dashboard with `"uid": "prometheus"` refs but the provisioning yaml omitted the explicit `uid:` field. Every panel showed "No data" until PR #156 pinned `uid: prometheus` in the provisioning yaml and a `docker restart monitoring-grafana` reloaded the datasource.

## `pct exec` from `ssh root@<pve-host>` is non-TTY — `STDIN.tty?` returns false

`ssh root@<pve-host> 'pct exec <vmid> -- bash -lc "..."'` does NOT propagate a TTY into the LXC. `STDIN.tty?` inside the inner bash returns `false`, even though the outer ssh session might have one. Plans that assume `pct exec` "is" TTY-equivalent (and therefore that `cookbooks/functions/default.rb` `require_external_auth` will use its TTY-prompted retry path) are wrong.

Concrete impact on `require_external_auth`-gated cookbooks:
- TTY context: `check_command` fails → 5-prompt retry loop → operator unblocks → block runs
- Non-TTY context (which `pct exec` over ssh IS): `check_command` fails → log warn → **block silently skipped** → mitamae continues with the auth-gated work undone

Symptom: cookbook reports apply success but follow-up verify shows the SSM-fetched resource (e.g. `/root/.ssh/authorized_keys` forced-command entry) is missing. Logs contain `[bootstrap] AWS SSM access (profile=<X>, region=<Y>) not configured AND STDIN is not a TTY — skipping auth-gated block.` — easily missed if you only tail the last 10 lines.

**Fix shape — apply once with auth seeded externally**:

For LXC-fleet cookbooks under the auto-mitamae pattern, seed the AWS profile (or whatever credential `require_external_auth` checks) BEFORE the first `mitamae local`. The two reliable channels:

1. **Operator script**: `bin/bootstrap-lxc-creds <CT>` (setup repo, 2026-05-07 onwards) — copies the profile from the PVE host into the fresh LXC via `pct exec` writes
2. **Env vars on first apply**: `AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... ./bin/mitamae local pve/lxc-X.rb`

Then orchestrator-driven subsequent applies have the auth in place and the gated block runs every cycle.

**Forcing TTY via `ssh -tt + pct exec` does NOT work** in our setup (tested 2026-05-06): `pct exec` strips the pty even when ssh allocates one. Don't try to engineer around the non-TTY status.

**Detection**:

```
git grep -nE 'pct exec.*--.*bash -lc' cookbooks/ pve/ docs/  # plans that assume TTY
```

Any plan / doc that talks about `pct exec` as "TTY apply" is suspect — replace the assumption with the seed-auth-then-apply pattern above.

This rule exists because the 2026-05-06 Phase 3a session walked into this assumption: 6 fleet hosts each needed a manual `aws configure set` step BEFORE mitamae apply, and the original plan's `pct exec` "TTY apply" framing didn't surface the prerequisite. Phase 3b/3c re-discovered it; Phase 3c started with an explicit AWS profile probe step (Stage 0) on every new host as a result.

## Privileged PVE LXC — systemd unit hardening directives fail with `status=226/NAMESPACE`

Inside a *privileged* PVE LXC (no `unprivileged: 1`), systemd's namespace-related unit directives fail at `ExecStart` with `Result: exit-code (status=226/NAMESPACE)`. Specifically these directives, all of which trigger systemd's mount-namespace setup:

- `ProtectSystem=strict` (or `=full`)
- `ProtectHome=yes`
- `PrivateTmp=yes`
- `NoNewPrivileges=yes`

Result: `Active: activating (auto-restart) (Result: exit-code)` in a tight 5-sec restart loop, no `Listening on …` log line, the daemon's port never opens. Direct invocation of the same binary from a shell on the same LXC works fine — the failure is purely in systemd's namespace setup colliding with the LXC's cgroup/namespace boundary.

**Drop-in overrides setting these to `=no` did NOT take effect** in our 2026-05-06 testing — `systemctl show` reported the new effective value, but the unit kept failing with the same `status=226/NAMESPACE`. The unit had to ship without the directives in the first place; `=no` overrides via drop-in were not sufficient.

**Detection**:

```
systemctl status <unit> --no-pager | grep -E 'status=226|NAMESPACE|activating'
pct config <vmid> | grep -E '^unprivileged:'   # absent → privileged LXC
```

If the LXC is privileged (no `unprivileged:` line) AND the unit status is `activating (auto-restart)` with `status=226/NAMESPACE`, the hardening is the cause.

**Fix shape**: ship the unit without `ProtectSystem` / `ProtectHome` / `PrivateTmp` / `NoNewPrivileges`. The defense-in-depth value is small for a LAN-internal port, and the operational cost of supporting both privileged and unprivileged LXCs in the fleet outweighs it. See setup PR #164 (`cookbooks/node-exporter/files/node-exporter.service`) for the canonical example.

**When designing new fleet cookbooks that ship systemd units**: assume any LXC in the fleet might be privileged (today only CT 100 roon is, but the rule is "support both"). Skip the namespace-related hardening directives in the cookbook-managed unit; if defense-in-depth is needed for a specific deployment, add a drop-in (which, as noted, may not actually take effect on privileged LXCs — accept the limitation).

This rule exists because setup PR #164 (2026-05-06) was required after Phase 3b apply on CT 100 left node-exporter cycling in `activating` state. CT 100 (roon) is the only privileged LXC in the home fleet (it predates the unprivileged-default convention). The hardening directives shipped fine on every other LXC; only privileged tripped over them.

## IAM principal that cannot self-rotate — design `bootstrap_profile` chain accordingly

A common security posture for fleet-deployed IAM principals (e.g., `pve-bootstrap-ssm` in home-monitor) is **least-privilege at runtime + cannot read its own credential SSM parameters**. This intentional asymmetry blocks credential-leak escalation: even with the leaked key, the attacker cannot read future rotated keys from SSM.

The asymmetry that misleads cookbook auth probes:
- `aws sts get-caller-identity --profile <P>` returns the principal's ARN (works for any valid IAM user, no specific permission needed)
- `aws ssm get-parameter --name <P's own credential path> --profile <P>` returns `AccessDeniedException`

A cookbook that uses `<P>` as `bootstrap_profile` and probes auth via `aws sts get-caller-identity` will **falsely conclude the profile is valid**, then fail at execute time when actually reading SSM. mitamae aborts.

**Design rule for any cookbook that distributes/rotates AWS credentials**:

1. Identify the IAM principal the cookbook will run under at fleet steady state
2. Check the home-monitor IAM policy: does that principal have `ssm:GetParameter` on the SSM paths the cookbook would read? Usually NO for the principal's own credential paths — deliberately
3. If NO, the cookbook **cannot self-rotate** under this principal. The bootstrap channel must be EXTERNAL:
   - Operator-supplied env vars (`AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY`) on first apply, OR
   - Pre-seeding from a parent host via a `bin/bootstrap-*` script (e.g. `bin/bootstrap-lxc-creds`), OR
   - A separate higher-privilege `bootstrap_profile` that IS allowed SSM read (admin profile, used out-of-band)
4. The cookbook should NOT treat the runtime profile as also being its own rotation source

**Auth probe must match the actual planned API call**:

```ruby
# WRONG: passes for any IAM user, doesn't reflect SSM access
auth_probe_cmd = "aws sts get-caller-identity --profile #{bootstrap} > /dev/null 2>&1"

# RIGHT: dry-run the actual SSM read on a representative path
first_spec = profiles.values.first
probe_path = first_spec[:access_key_id_ssm]
auth_probe_cmd = "aws ssm get-parameter --name '#{probe_path}' --output text" \
                 " --profile '#{bootstrap}' --region '#{region}' > /dev/null 2>&1"
```

This is the rule generalization of "Auth-check gate must match the cookbook's actual invocation profile" (see `cookbooks/ruby.md`) applied to `bootstrap_profile` probes specifically.

**Detection grep** when reviewing fleet cookbooks:

```
git grep -nE 'bootstrap_profile.*pve-bootstrap-ssm|aws sts get-caller-identity.*profile' cookbooks/
```

Any fleet-host cookbook using its OWN runtime IAM identity as `bootstrap_profile` is a candidate to verify against the home-monitor IAM policy.

This rule exists because setup PR #166 (2026-05-07, aws-credentials systematic-化) included `aws-credentials` in `auto-mitamae-target` with `bootstrap_profile=pve-bootstrap-ssm`. The cookbook's `aws sts get-caller-identity` probe passed; the actual `aws ssm get-parameter` then failed with `AccessDeniedException` on `/home-monitor/iam/pve-bootstrap-ssm/access-key-id`. Recovery required revert PR #167 + manual re-apply on CT 111. The IAM policy denial is intentional — `pve-bootstrap-ssm` cannot read its own credential paths to prevent self-rotation as a privilege-escalation surface. The cookbook now uses the external `bin/bootstrap-lxc-creds` script as the systematic-化 channel instead.
