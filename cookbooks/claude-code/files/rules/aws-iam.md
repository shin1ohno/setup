---
description: "AWS IAM / SSM / Terraform operational rules — perpetual drift, SSM path constraints, IAM self-rotate, STS refresh, terraform branch gate, stale state lock"
---

# AWS IAM / SSM / Terraform Operational Rules

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

## Stale Terraform State Lock Recovery

When `terraform plan` or `terraform apply` aborts with `Error acquiring the state lock`, the previous run left a DynamoDB lock that was not released (process killed, network drop, container shutdown). Recovery:

1. Read the lock ID from the error block (`ID: a845a182-6011-acf6-e431-005ee971d1c5`)
2. Confirm no other apply is in flight — check background sub-agents (`TaskList`), other terminals on the same host, and the lock's `Who` / `Created` fields in the error to gauge age
3. `terraform force-unlock -force <lock-id>`
4. Re-run the original command

Never `force-unlock` while another apply may legitimately hold the lock — overlapping writes corrupt state. Stale locks more than ~10 min old with no visible apply process are safe to break.

This rule exists because the 2026-05-04 PVE-migration session inherited a 14-hour-old lock from a yesterday-aborted apply; rediscovering the `force-unlock` path cost time. The lock's `Who: shin1ohno@pro-dev` field made it identifiable as a self-orphan.

## Short-lived STS Token Refresh Before Multi-Host mitamae Apply

`aws-login` / `aws sso login` issues STS tokens with 15-60 minute lifetimes. A multi-LXC mitamae batch (8+ hosts in sequence with image pulls) can outlast a freshly-fetched token. Tokens that were `scp`'d to LXC nodes go stale **independently** of the local copy — even if `aws sts get-caller-identity` still works on the orchestrator, the LXC's `~/.aws/credentials` may already be expired.

Pre-batch checklist:

1. `aws sts get-caller-identity --profile <profile>` immediately before launching the batch — confirms the local token is valid
2. If credentials are SCP'd to LXCs: re-SCP after every refresh; do not assume the local-side validity propagates
3. For batches expected to take >10 min: refresh + re-SCP at the start AND set a wakeup to re-check at half the token lifetime
4. Prefer **IAM instance profiles** on LXCs (or workload-identity equivalents) over SCP'd temporary credentials — instance profiles auto-rotate via IMDS and never need re-SCP

This rule exists because the 2026-05-04 PVE-migration session burned 4 separate refresh-and-re-SCP cycles when the token expired mid-batch. Each cycle required pausing apply, re-fetching, re-distributing, then resuming — a ~3-min loss per cycle that is fully preventable by pre-batch validation + instance profiles for steady-state.

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
