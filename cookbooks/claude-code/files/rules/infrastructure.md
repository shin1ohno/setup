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

## Long-Running Operations

`terraform plan`, `terraform apply`, and other commands that typically take 30+ seconds must run in a background sub-agent (`run_in_background: true`) so the main conversation remains interactive. Pattern:

1. Launch a background agent that runs the command and parses the output
2. Continue interacting with the user (answer questions, start other work)
3. When the agent completes, present the results and ask for next steps

This applies to: `terraform plan/apply`, `docker build`, long test suites, and any command where the user cannot usefully intervene mid-execution.

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
