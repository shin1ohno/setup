---
description: "AWS IAM / SSM / Terraform operational rules — perpetual drift, SSM path constraints, IAM self-rotate, STS refresh, terraform branch gate, stale state lock"
---

# AWS IAM / SSM / Terraform Operational Rules

This file is the always-loaded summary. Long examples + origin notes are in `~/.claude/docs/aws-iam-detail.md` (NOT auto-imported — load on demand via Read tool when a section pointer matches the current task).

## Perpetual Drift Decision Framework

`terraform plan` showing the same attribute diff on every run — especially one marked `forces replacement` — is not a one-off glitch; it is perpetual drift. Every apply replaces real resources to chase a cosmetic discrepancy.

**Trigger**: when the same diff survives a successful apply (run `terraform plan` again immediately — same attribute still shows), treat it as perpetual drift and pick a fix *before* the next apply. Do not accept "one more apply will clear it" for the third time.

**Decision flow** — pick in this order of preference; `ignore_changes` is last resort, not first reach:

- **A. Redesign away the pressure point** — if the forcing attribute is load-bearing for the architecture (e.g., instance in a public subnet with EIP, while Tailscale would be equally happy in a private subnet behind NAT), reconsider whether the resource belongs where it is. Most expensive change, but leaves nothing to fight later
- **B. Suppress the drift at its source** — if the drifting attribute is inherited from a parent resource setting (subnet `map_public_ip_on_launch`, VPC-level defaults, launch-template defaults), change that parent setting if only this resource uses it. Cheapest root-cause fix when the parent is scoped to the consumer
- **C. Match reality in the config** — if the attribute's actual value is harmless and intentional at the AWS level, update the Terraform config to match it. state == reality, no ignore list. Pays one replacement cost up front; free after that
- **D. `lifecycle.ignore_changes = [attr]`** — only when the attribute is purely cosmetic and A/B/C are disproportionate to the noise. Leaves a permanent state-vs-reality gap; always accompanied by an inline comment explaining *why* Terraform should stop reconciling this attribute

**Trap**: D looks the cheapest so it attracts first. It also hides future *real* drift on the same attribute (e.g., AWS deprecates the auto-assign default; you never see it). Prefer A/B/C unless the scope genuinely forbids them.

**Commit-message guidance for D**: name the parent setting that forces the drift (e.g., "aws_subnet.c_public has map_public_ip_on_launch=true"), not just the symptom. The next reader needs to know which of A/B/C was rejected and why.

Origin: 2026-04-22 incident cascaded through 4 EC2 generations before root cause.

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

Origin: 2026-04-25 feature-branch apply denied → merge-first flow.

**Post-apply sanity check**: after `terraform apply` returns, run `terraform validate` (or a no-op `terraform plan -refresh-only`) to confirm the working tree's config files are still self-consistent. Mid-session edits, stash/pop interactions, or manual reverts can leave the tf file syntactically intact (no parse error) but resource-name-duplicated — the error surfaces only on the next operation, often hours later.

```bash
terraform apply -target=... -auto-approve
terraform validate   # → "Success! The configuration is valid."
```

If validate reports `Duplicate ... configuration`, the most common cause is a stash/pop or manual edit that re-introduced an already-committed block into the working tree. `git diff HEAD -- <file>.tf` will show the duplicate hunk. Recovery: `git checkout HEAD -- <file>.tf` if the only WIP was the unintended duplication, or surgical removal of the duplicate hunk if there are other legitimate WIP changes.

Origin: 2026-05-11 RDS RI apply → `Duplicate data "aws_rds_reserved_instance_offering"` from stash-pop merge.

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

Origin: 2026-05-06 `aws_ssm_parameter` at `/aws-keys/pve-bootstrap-ssm/access-key-id` → `AccessDeniedException: No access to reserved parameter name`; clean plan, apply-time failure. Renamed to `/home-monitor/iam/pve-bootstrap-ssm/...`.

## Stale Terraform State Lock Recovery

Detail: see `~/.claude/docs/aws-iam-detail.md#stale-state-lock`.

## Short-lived STS Token Refresh Before Multi-Host mitamae Apply

Detail: see `~/.claude/docs/aws-iam-detail.md#sts-token-refresh`.

## Multi-profile auth chain — enumerate every profile's IAM scope at design time

Detail: see `~/.claude/docs/aws-iam-detail.md#multi-profile-auth-chain`.

## IAM principal that cannot self-rotate — design `bootstrap_profile` chain accordingly

Detail: see `~/.claude/docs/aws-iam-detail.md#iam-cannot-self-rotate`.

## Fleet Cookbook SSM Gate Path Must Match the Profile's IAM Grant

Detail: see `~/.claude/docs/aws-iam-detail.md#fleet-ssm-gate-path`.

### Fleet cookbook profile-gate patterns (post-#503)

Do NOT re-propose "every fleet cookbook must pin `--profile`" — that guidance predates #503 and is now stale (stale rules are the vector by which future sessions re-suggest an already-rejected pin-everything design). Three current patterns for how a cookbook resolves its AWS profile:

- **darwin / TTY (manual operator)** — bare gate + `require_external_auth` auto-discovery (Pattern B; e.g. `mcp`, `local-mcp`)
- **fleet / non-TTY** — bare gate + `mitamae-runner.sh` presets `export AWS_PROFILE=pve-bootstrap-ssm` before apply (lint `BARE_OK` category)
- **explicit `--profile` pin** — only the residual cookbooks not yet on the runner preset

Full mechanics (auto-discovery TTY-only behavior, lint checks) live in `~/.claude/docs/aws-iam-detail.md#multi-profile-auth-chain`; the pre-#503 "MUST pin" wording there still needs the same correction. Origin: #503 moved fleet gating to the runner preset.

## Probe preconditions on the real host with the real credential resolution chain

Before asserting a precondition (SSM grant present, terraform runnable, "auth unavailable"), probe the ACTUAL condition on the ACTUAL execution host — credential fall-through produces false positives.

1. **SSM grant probe must run on the target host, not the admin terminal.** A probe with the correct `--profile <target>` still false-positives when run from a different host: that host's credential resolution chain (`~/.aws` cache, `source_profile`, `credential_process`) can fall through to an admin identity (`sh1admn` etc.) and succeed. Probe success only proves "this identity on this host" can read. Verify a fleet cookbook's gate path from the actual target CT/LXC, and confirm the identity ARN from `aws sts get-caller-identity` matches the intended principal before concluding "IAM grant not needed". Origin: 2026-06 es-memory — a `--profile pve-bootstrap-ssm` probe from `mini` succeeded on the `sh1admn` cache, "grant not needed" was wrongly concluded, CT119 hit a real AccessDenied post-deploy; fixed by path change.

2. **Probe `test -f terraform.tfvars` on the executing host before `terraform plan/apply`.** `*.tfvars` is gitignored and present only on ops hosts; on a host without it, apply falls through to an interactive prompt for every variable (`Enter a value:`), inviting hand-entry of secrets like `break_glass_pubkey` (a mistyped value can propagate via SSM). Origin: 2026-06-27 apply on `mini` dropped into `var.aws_profile` / `var.break_glass_pubkey` prompts, Ctrl-C aborted.

3. **Don't assert sandbox AWS-auth absence as an un-reprobable hard boundary.** `aws login` writes the `~/.aws` file cache, so re-probe after the user logs in. A bare `aws` CLI rc=1 is not proof of "no auth" — the sandbox zsh's compdef bug can kill the CLI itself (see auto-memory `aws-cli-needs-bash-c-wrapper`). Probe via `/bin/bash -c 'aws sts get-caller-identity --profile <P>'` or a read-only `terraform plan`; if the plan passes, the apply can run in-session too. Origin: 2026-06-27 — asserted "hard boundary, only runnable on your machine", then a read-only plan succeeded and apply completed in-sandbox.

## kms:Decrypt with EncryptionContext — wildcard `*` denies silently

When granting `kms:Decrypt` to a role that needs to read SSM SecureString
parameters, AWS encrypts the parameter value with a KMS data key bound
to an `EncryptionContext` of the form:

```json
{ "PARAMETER_ARN": "arn:aws:ssm:<region>:<account>:parameter/<name>" }
```

The IAM `Condition` block on `kms:Decrypt` MUST match this context with
the **explicit account ID**. A wildcard like
`"arn:aws:ssm:*:*:parameter/<name>"` looks reasonable but is rejected by
KMS's StringLike evaluator — every Decrypt call returns
`AccessDeniedException: ciphertext refers to a customer master key that
does not exist, does not exist in this region, or you are not allowed
to access`. The error message **does not name the missing condition** —
the failure looks like a missing key reference rather than an unmet
condition.

**Wrong** (wildcard, silently denies every Decrypt):

```hcl
condition {
  test     = "StringLike"
  variable = "kms:EncryptionContext:PARAMETER_ARN"
  values = [
    "arn:aws:ssm:*:*:parameter/home-monitor/secrets/tailscale-oauth-client-id",
    "arn:aws:ssm:*:*:parameter/home-monitor/secrets/tailscale-oauth-client-secret",
    "arn:aws:ssm:*:*:parameter/tailscale/auth-key",
  ]
}
```

**Right** (explicit account ID, derived from `data.aws_caller_identity`):

```hcl
data "aws_caller_identity" "current" {}

condition {
  test     = "StringLike"
  variable = "kms:EncryptionContext:PARAMETER_ARN"
  values = [
    "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/home-monitor/secrets/tailscale-oauth-client-id",
    "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/home-monitor/secrets/tailscale-oauth-client-secret",
    "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/tailscale/auth-key",
  ]
}
```

**Why wildcards fail**: KMS rejects wildcarded account IDs in EncryptionContext conditions for the SSM SecureString integration — the context must be an **exact** ARN. `StringLike` is for forward-compat with SSM internal evolution, not caller-side abbreviation.

**Detection signal**: an IAM role that *should* have `kms:Decrypt` is
denied on every SSM SecureString GetParameter call with `--with-decryption`,
returning the misleading "ciphertext refers to a CMK that does not
exist" error. Probe with `aws iam get-role-policy ... --query
'PolicyDocument.Statement[?contains(Action, kms:Decrypt)]'` and look
for `*:*:parameter/...` ARNs in the EncryptionContext condition.

**Fix shape**: always use `${var.aws_region}` (already known at TF
parse time) + `${data.aws_caller_identity.current.account_id}`
(authoritative). If you need to grant Decrypt across multiple regions,
enumerate each region explicitly — never wildcard the region either,
same evaluator restriction.

Origin: 2026-05-10 KMS Decrypt for Tailscale rotation shipped wildcarded ARNs → `AccessDeniedException` on every SSM `GetParameter` with no error clue. Replaced with `data.aws_caller_identity.current.account_id`.

## Tailscale OAuth client scope — UI/API divergence requires API-side verification

Detail: see `~/.claude/docs/aws-iam-detail.md#tailscale-oauth-ui-divergence`.

## Reusable Tailscale auth keys for ephemeral compute

Detail: see `~/.claude/docs/aws-iam-detail.md#reusable-tailscale-keys`.

## Cost Table Labeling Conventions

Detail: see `~/.claude/docs/aws-iam-detail.md#cost-table-labeling`.

## KMS request attribution — query ssm:GetParameter, not kms:Decrypt

Detail: see `~/.claude/docs/aws-iam-detail.md#kms-attribution-query`.
