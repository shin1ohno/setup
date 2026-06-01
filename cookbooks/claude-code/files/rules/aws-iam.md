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

**Post-apply sanity check**: after `terraform apply` returns, run `terraform validate` (or a no-op `terraform plan -refresh-only`) to confirm the working tree's config files are still self-consistent. Mid-session edits, stash/pop interactions, or manual reverts can leave the tf file syntactically intact (no parse error) but resource-name-duplicated — the error surfaces only on the next operation, often hours later.

```bash
terraform apply -target=... -auto-approve
terraform validate   # → "Success! The configuration is valid."
```

If validate reports `Duplicate ... configuration`, the most common cause is a stash/pop or manual edit that re-introduced an already-committed block into the working tree. `git diff HEAD -- <file>.tf` will show the duplicate hunk. Recovery: `git checkout HEAD -- <file>.tf` if the only WIP was the unintended duplication, or surgical removal of the duplicate hunk if there are other legitimate WIP changes.

This second rule exists because 2026-05-11 RDS RI apply (home-monitor PR #65) was followed by `terraform output` failing with `Duplicate data "aws_rds_reserved_instance_offering" configuration` — the working tree had the RI block twice due to a stash-pop merge. `git checkout HEAD -- rds.tf` cleaned it, but a `terraform validate` immediately post-apply would have caught it in the same minute instead of surfacing on the next `terraform output` minutes later.

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

## Multi-profile auth chain — enumerate every profile's IAM scope at design time

Before designing any flow that chains "admin profile auths → fetch service-profile keys from SSM → service profile reads downstream paths", enumerate the **real SSM-path-level permission** of every profile in the chain on a representative path the downstream cookbook will actually read.

`aws sts get-caller-identity` is insufficient — it succeeds for any valid identity regardless of SSM scope. The probe must hit the downstream-targeted path:

```bash
# For each profile in the chain (bootstrap + service):
aws ssm get-parameter \
  --name "<actual-path-cookbook-will-read>" \
  --profile "<profile>" \
  --region "<region>" \
  > /dev/null 2>&1 && echo "OK" || echo "DENY"
```

If the service profile returns `DENY` for a path the downstream cookbook needs, the chain is structurally broken regardless of how reliably the upstream admin auth works. Either:

1. Expand the service profile's IAM policy to include the missing paths (home-monitor TF change), OR
2. Switch the downstream cookbook to use a different profile that has the access, OR
3. Abandon the design — the cookbook's existing `skip_if: File.exist?(env_output_path)` may already cover the gap on warm re-runs

This applies equally to **`kms:Decrypt`** chains for SSM SecureString (see the `EncryptionContext` rule below — even with sts identity working and ssm:GetParameter granted, missing `kms:Decrypt` on the parameter's KMS context still returns AccessDeniedException at fetch time).

This rule exists because the 2026-05-11 PR #339+#340 designed a two-stage `aws login --remote → aws-credentials fetches pve-bootstrap-ssm` flow that was structurally moot: `pve-bootstrap-ssm` has `/ssh-keys/*` only, not `/cognee/*`, so even a perfectly-working sh1admn admin auth couldn't fix `aws ssm get-parameter --name /cognee/llm-endpoint --profile pve-bootstrap-ssm`. The 30-second per-profile probe at design time would have caught this. Reverted via PR #343.

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

**Why wildcards fail**: KMS evaluates the EncryptionContext condition
as exact-match on each entry; the StringLike pattern is treated as a
literal pattern that never matches a real ARN unless the wildcard
positions align with the actual ARN structure. Even when they "could"
align, KMS's policy engine specifically rejects wildcarded account IDs
in EncryptionContext conditions for the SSM SecureString integration —
the documented behavior is that the context must be an **exact** ARN,
and `StringLike` provides forward-compat for SSM internal evolution,
not for caller-side abbreviation.

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

This rule exists because home-monitor PR #57 (2026-05-10, KMS Decrypt
for Tailscale rotation script) shipped wildcarded ARNs in the
EncryptionContext condition. The on-EC2 systemd-timer rotation script
hit `AccessDeniedException` on every SSM `GetParameter`, with no clue
in the error message that the EncryptionContext condition was the
cause. PR #58 replaced the wildcards with `data.aws_caller_identity.current.account_id`
and the next timer fire (`[2026-05-10T17:32:48+00:00] Tailscale auth
key rotated`) succeeded. The diagnostic arc cost one PR + one re-apply
+ one wakeup wait for timer fire — all preventable by writing the
explicit account ID at PR design time.

## Tailscale OAuth client scope — UI/API divergence requires API-side verification

Tailscale's admin UI for OAuth client editing (`/admin/settings/oauth/<id>/edit`)
sometimes shows scope checkboxes (e.g. `Auth Keys: Read ✓ Write ✓`)
in a state that does NOT match what the API enforces. The Save banner
appearing is not authoritative — the API call still rejects key-mint
attempts with `requested tags '<list>' invalid or not permitted (400)`,
even though the tag list is correctly enumerated and the UI shows the
required scope as granted.

Empirical signature of this divergence:

- UI shows checkbox state X for scope Y
- `POST /api/v2/oauth/token` succeeds (the client itself is valid)
- `POST /api/v2/tailnet/-/keys` with the minted token fails with 400
  `tags ... invalid or not permitted` regardless of which valid tag
  combination is passed

**Mandatory verification** before treating any OAuth client as functional:

```bash
CLIENT_ID=$(aws ssm get-parameter --name <id-path> --with-decryption \
  --query 'Parameter.Value' --output text --profile <profile>)
CLIENT_SECRET=$(aws ssm get-parameter --name <secret-path> --with-decryption \
  --query 'Parameter.Value' --output text --profile <profile>)
TOKEN=$(curl -s -X POST -d "client_id=$CLIENT_ID" -d "client_secret=$CLIENT_SECRET" \
  https://api.tailscale.com/api/v2/oauth/token | jq -r '.access_token')
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  https://api.tailscale.com/api/v2/tailnet/-/keys \
  -d '{"capabilities":{"devices":{"create":{"reusable":true,"ephemeral":true,"preauthorized":true,"tags":["<your-tag-list>"]}}}}' \
  | jq '.key // .message'
```

Expected: `"tskey-auth-..."`. If `"... invalid or not permitted"`
appears, the OAuth client is broken and the only known recovery is to
**create a fresh OAuth client** in the admin UI (not edit the existing
one) and update the SSM parameters. Editing the existing client and
re-saving has been observed to leave the API state unchanged.

**When this matters**:

- Adding a new tailscale_tailnet_key resource referencing this OAuth
  client → `terraform apply` will fail at create-time
- The on-EC2 60-day rotation timer for the auth key → silent timer
  failure, SSM `/tailscale/auth-key` slowly drifts toward expiry
- EC2 replacement → first boot `tailscale up --auth-key` rejects the
  stale SSM key → user_data Phase 01 fail → no nginx, no cert, public
  endpoints DOWN

**Don't trust the UI state**. Always run the API verification curl
chain before merging any TF / cookbook change that depends on the
OAuth client minting a key. Five seconds at PR time prevents a
multi-hour incident at apply / boot time.

This rule exists because the 2026-05-10 home-monitor incident traced
to OAuth client `kLoCzbwNyn11CNTRL` whose admin UI showed `Auth Keys:
Read ✓ Write ✓` while the API returned `tags ... invalid or not
permitted` for every tag combination. Recovery required generating a
brand-new OAuth client `kBiQ8wcpEB21CNTRL`, updating SSM, and verifying
via the curl chain above. The runbook for this failure mode is at
`~/ManagedProjects/home-monitor/docs/runbooks/tailscale-key.md`.

### Scope-to-endpoint reference — probe the RIGHT endpoint for each scope

Tailscale's UI scope categories do NOT map 1-to-1 to API endpoint families. Notably,
**Routes is a sibling top-level scope, NOT a sub-scope of Devices Core** — the
`/api/v2/device/<id>/routes` endpoint requires `Routes`, even though it lives under
the `/device/<id>/` URL prefix. Probing `devices:core:write` via the routes endpoint
returns 403 even when the scope IS granted, leading to false "scope didn't propagate"
conclusions.

When verifying an OAuth client's scopes, probe each UI scope category with its actual
representative endpoint:

| UI scope label        | Representative probe                                                                  | Pass signal               |
|-----------------------|---------------------------------------------------------------------------------------|---------------------------|
| Devices Core: Read    | `GET /api/v2/tailnet/-/devices`                                                       | HTTP 200 + devices array  |
| Devices Core: Write   | `POST /api/v2/device/<id>/tags` body `{"tags":["tag:foo"]}`                           | HTTP 200                  |
| Routes: Read          | `GET /api/v2/device/<id>/routes`                                                      | HTTP 200 + routes object  |
| Routes: Write         | `POST /api/v2/device/<id>/routes` body `{"routes":[...]}` (idempotent re-write OK)    | HTTP 200                  |
| DNS: Read             | `GET /api/v2/tailnet/-/dns/split-dns`                                                 | HTTP 200                  |
| DNS: Write            | `POST /api/v2/tailnet/-/dns/split-dns/<domain>` body `{"nameservers":[...]}`          | HTTP 200                  |
| Auth Keys: Write      | `POST /api/v2/tailnet/-/keys` (body per existing rule)                                | HTTP 200 + `tskey-auth-`  |

When the actual terraform resource is `tailscale_device_subnet_routes`, the missing
scope is **Routes**, not `Devices Core: Write`. When the resource is
`tailscale_dns_split_nameservers`, the missing scope is **DNS**. Match the probe to
the scope you're verifying — not to a guess about which scope category the endpoint
URL appears to belong to.

### Same error on a freshly-created client = hypothesis is wrong, not drift

The "create a fresh OAuth client" workaround above is the recovery for genuine UI/API
divergence. It is NOT the recovery for "I configured the wrong scope". If a
brand-new client (never edited) returns the **same 403** as the prior client on the
**same endpoint** with **all UI-visible scopes checked**, the configuration mental
model is wrong — not the persistence.

Action gate when a fresh client reproduces the failure:

1. Stop reaching for "UI/API drift" or "tag scope mismatch" explanations
2. Probe other write endpoints under the scope you THINK should cover this call
   (e.g. `POST /device/<id>/tags` to verify `Devices Core: Write` independently of
   the failing endpoint)
3. If the sibling probe returns 200, the scope IS granted — the failing endpoint
   requires a different scope. Consult the scope-to-endpoint table above.
4. If the sibling probe also returns 403, then the scope itself is not granted —
   re-check the UI checkbox state, and only then suspect drift

This rule exists because the 2026-05-11 home-monitor session created a fresh
OAuth client (`koFXKg78P311CNTRL`) with all 4 ticked scopes after the prior client
(`kBiQ8wcpEB21CNTRL`) returned 403 on `/device/<id>/routes`. The fresh client
returned identical 403s. I interpreted this as a tag-scope mismatch (`hnd-subnet-router`
has only `tag:home-router`, not in the OAuth client's tag list) and burned 2-3
round-trips before probing `POST /device/<id>/tags` and getting 200 — proving
`Devices Core: Write` was fine and the actual missing scope was **Routes**, a
separate top-level UI category. Two-fresh-clients-same-result was a sufficient
signal at iteration 2 to pivot the hypothesis away from drift.

## Reusable Tailscale auth keys for ephemeral compute

When provisioning a Tailscale tailnet key (`tailscale_tailnet_key`
resource) for an EC2 / Auto Scaling Group / similar replaceable
compute instance, set `reusable = true` unless there's a documented
reason to enforce single-use. Single-use (`reusable = false`) breaks
EC2 replacement workflows in a non-obvious way:

- AWS auto-recovery, AMI bumps, `terraform taint`, or any
  `user_data_replace_on_change` trigger destroys the instance
- The new instance boots, runs user_data, fetches the same SSM key,
  calls `tailscale up --auth-key=<key>` → rejected with `invalid key:
  API key <id> not valid` because the prior boot consumed it
- All downstream user_data phases (TLS, Docker, nginx) skip → public
  endpoints DOWN until manual intervention

`reusable = true` allows the same SSM-stored key to authenticate
unlimited boots. The key still expires (90-day default), so pair with
a rotation timer (on-EC2 systemd timer minting fresh keys via the
OAuth client) to keep the SSM value valid indefinitely.

```hcl
resource "tailscale_tailnet_key" "subnet_router" {
  reusable      = true              # MUST for ASG/replaceable EC2
  ephemeral     = false
  preauthorized = true
  expiry        = local.tailscale_key_expiry_seconds  # 90 days
  description   = "AWS VPC subnet router for home monitoring"
  tags          = ["tag:subnet-router", "tag:aws", "tag:home-monitoring"]

  lifecycle {
    create_before_destroy = true
  }
}
```

**Don't pair this with `single_use = true`** on the rotated key either
— the rotation script writes a fresh key to SSM, but if the next EC2
boot races with a manual rotation, the boot's fetch and the rotate's
put may conflict and leave a single-use key already-consumed before
the boot's `tailscale up` runs.

The complete pattern (reusable key + 60-day rotation timer + KMS
Decrypt with explicit account ID) is documented in
`~/ManagedProjects/home-monitor/docs/runbooks/tailscale-key.md`.

This rule exists because home-monitor's `tailscale_tailnet_key` was
originally `reusable = false` for a defensive single-use posture
(2025 design). The 2026-05-10 EC2 auto-recovery cycle terminated the
running EC2 mid-incident, the new EC2 booted, and `tailscale up`
rejected the consumed SSM key. mcp.ohno.be went DOWN for the duration
of the recovery (~30 min including OAuth-scope-drift discovery). PR
#56 changed to `reusable = true` and PR #57+#58 added the timer +
Decrypt grants for the long-term fix.

## Cost Table Labeling Conventions

When presenting AWS cost breakdowns to the user, use **explicit category labels** instead of generic 「小計」/「合計」. The mismatch between recurring base cost and annual spikes is a frequent source of misunderstanding — a single line "subtotal $X" mixing recurring + annual + spike cannot tell the reader whether $X is a typical month, a worst-case month, or includes one-off charges.

**Required label categories**:

| Label | Meaning |
|---|---|
| `月次固定 (recurring)` | Every month, predictable baseline |
| `年次スパイク (annual)` | Charges that occur once per year (domain renewal, RI upfront, audit etc.) |
| `削減後ベース (post-action)` | Projected month-end after a fix lands (after RI / feature off / migration) |
| `当月実績 (MTD actual)` | Cost Explorer reported amount for the partial month |

**Anti-pattern**:

```
| Service       | 小計  |
| RDS           | $20   |
| Route53       | $1.66 |
| ...           | ...   |
| 合計          | $48   |
```

What does $48 cover? Recurring? With or without the annual Registrar charge? Post or pre RI? The user has to ask.

**Correct shape**:

```
| Service       | 月次固定 | 年次スパイク         | 削減後ベース       |
| RDS           | $20.00  | $0                  | $13.42 (post-RI)  |
| Route53       | $1.66   | $11 (Registrar 4月) | $1.66             |
| ...           |         |                     |                   |
| **Subtotal**  | $X      | $Y (next: 4月)      | $Z                |
```

When the totals would mix categories, split the totals row by category — never a single ambiguous 「合計」.

**For RI-related accounting, label both**:

- **UnblendedCost** (実支払額 — RI upfront lands in the purchase month as a $-spike)
- **AmortizedCost** (実態の月次負担 — RI cost spread over the commitment period)

When discussing a month where RI was purchased, present both views side by side. UnblendedCost without context looks like a cost explosion; AmortizedCost reflects the true monthly burden.

This rule exists because the 2026-05-11 cost-analysis session presented 「小計 (RDS 以外) ~$20/月」 while the actual 4月 total for that group was $47.64 (containing Registrar $11 annual + ELB/WAF residue from discontinued services + Tax). The user had to ask 「これは何？」 to surface the missing context; the 5月 projection was actually $27/月 due to the annual Registrar not recurring. The vague 「小計」 label hid the discontinuity entirely.
