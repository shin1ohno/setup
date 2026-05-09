# Runbook: pve-bootstrap-ssm IAM Access Key Rotation

**Status**: Active (Phase B-1, 30-day soak in progress)
**Owner**: operator (`sh1admn` admin profile required)
**Frequency**: every 30 days, or on suspicion of credential leak
**Cross-references**:
- ADR-0003 (IAM trust boundary = repo boundary)
- ADR-0004 (host registry via SSM)
- `~/ManagedProjects/home-monitor/scripts/rotate_pve_bootstrap_iam_key.sh` (the script this runbook drives)
- `~/ManagedProjects/home-monitor/pve-bootstrap-iam.tf` (Terraform definition of the two-key set)
- `~/ManagedProjects/setup/bin/bootstrap-lxc-creds` (consumer-side lazy re-seed)

## Overview

The `pve-bootstrap-ssm` IAM user holds two access keys at all times — labelled `primary` and `secondary` in Terraform state, exposed at `/home-monitor/iam/pve-bootstrap-ssm/{primary,secondary}/{access-key-id,secret-access-key}` SSM SecureString. Consumer cookbooks (mitamae `cookbooks/aws-credentials`, `bin/bootstrap-lxc-creds`) read the **legacy alias** `/home-monitor/iam/pve-bootstrap-ssm/{access-key-id,secret-access-key}` which points at whichever key is currently active. Rotation flips which key the alias references and disables the old one.

The two-key shape is required because AWS limits each IAM user to 2 access keys; rotating with only 1 key would leave a window with zero valid credentials.

## Rotation procedure

Run from `~/ManagedProjects/home-monitor` with `AWS_PROFILE=sh1admn` (admin permissions required for `iam:UpdateAccessKey`, `ssm:PutParameter` on `/home-monitor/iam/*`, and `terraform apply`).

### Step 1 — Pre-flight: confirm consumer health

Before rotating, verify all consuming hosts are currently healthy. The rotation script's grace period (1 hour by default) assumes the orchestrator's 5-minute cycle re-seeds any host that loses creds — if the orchestrator is broken, hosts that lose creds during rotation will stay broken until manual intervention.

```bash
# Confirm orchestrator is running and re-seed metric is fresh
ssh root@pve.home.local "systemctl status auto-mitamae-orchestrator.service"
curl -s http://monitoring.home.local:9100/metrics | grep bootstrap_lxc_creds_last_attempt_timestamp_seconds
# Each host's timestamp should be within the last 10 minutes.
```

If any LXC's last-attempt timestamp is stale (>15 min), fix orchestrator FIRST. Do not proceed to rotation.

### Step 2 — Run the rotation script

```bash
cd ~/ManagedProjects/home-monitor
AWS_PROFILE=sh1admn ./scripts/rotate_pve_bootstrap_iam_key.sh
```

The script performs four phases automatically:

1. **Pre-flight checks** — verifies `AWS_PROFILE=sh1admn` access, confirms exactly 2 access keys exist on the IAM user (aborts on `<2` or `>2`), reads current legacy alias key id and secondary key id (aborts if they match — inconsistent state).
2. **Swap the legacy alias** — overwrites `/home-monitor/iam/pve-bootstrap-ssm/{access-key-id,secret-access-key}` with the secondary key's values via `aws ssm put-parameter --overwrite`. The Terraform `lifecycle { ignore_changes = [value] }` on the alias resource preserves this overwrite across future `terraform apply` runs.
3. **Disable the old primary in IAM** — `aws iam update-access-key --status Inactive` on the previously-active key. Any consumer still cached on the old credentials will start failing within minutes (the AWS SDK does not blacklist Inactive keys instantly, but session caching typically expires within 5 min).
4. **Grace period (default 3600s)** — sleeps 1 hour to let `auto-mitamae-orchestrator` `ensure_creds()` re-seed any failing host. Override with `GRACE_SECONDS=<n>` if needed.

After step 3 the script `terraform taint`s the old primary so the next `terraform apply` will destroy and recreate it as a fresh secondary.

### Step 3 — Apply Terraform to provision the new secondary

The script does not run `terraform apply` automatically. After grace period exit:

```bash
cd ~/ManagedProjects/home-monitor
terraform plan
# Verify ONLY these changes:
#   ~ aws_iam_access_key.pve_bootstrap_ssm["primary"]   destroyed + recreated
#   ~ aws_ssm_parameter.pve_bootstrap_ssm_rotation_credentials["primary/access-key-id"]
#   ~ aws_ssm_parameter.pve_bootstrap_ssm_rotation_credentials["primary/secret-access-key"]
# Nothing should touch the legacy alias resources, the secondary resources, or unrelated infra.

terraform apply
```

**Trap (risk #5 from adversarial review)**: if Terraform plan shows changes to `aws_ssm_parameter.pve_bootstrap_ssm_credentials["access-key-id"]` or `["secret-access-key"]` (the legacy alias), DO NOT APPLY. The `lifecycle { ignore_changes = [value] }` should suppress all value drift on the alias. If a diff appears anyway, it means a non-`value` attribute (description, tags, type) drifted — investigate before applying. Applying would silently revert the rotation by overwriting the alias back to the original primary key.

### Step 4 — Verify rotation completed

```bash
# (a) Both keys exist, one Active and one Active (the new one is in "primary" map slot).
aws iam list-access-keys --user-name pve-bootstrap-ssm --profile sh1admn

# (b) Legacy alias points at the new key (whichever was previously secondary).
aws ssm get-parameter --name /home-monitor/iam/pve-bootstrap-ssm/access-key-id \
  --with-decryption --profile sh1admn --query 'Parameter.Value' --output text

# (c) Consumer health: pick a representative LXC and verify it can still authenticate.
ssh root@pve.home.local "pct exec 109 -- aws sts get-caller-identity --profile pve-bootstrap-ssm"

# (d) SNS audit email arrived (CloudTrail event rule → us-east-1 SNS).
# Check admin_email inbox for 3 messages from CloudWatch Events:
#   - UpdateAccessKey (Inactive on old primary)
#   - DeleteAccessKey (terraform apply destroying old primary)
#   - CreateAccessKey (terraform apply creating new secondary)
```

If any consumer in (c) returns `InvalidClientTokenId`, run `bin/bootstrap-lxc-creds <CT>` from the PVE host to force-re-seed that LXC. The orchestrator's lazy re-seed typically catches this within 5 min, but a manual force is the immediate remedy.

## Post-rotation logging

Record rotation completion in the operator log. Suggested format:

```
2026-XX-XX rotation complete.
  Old primary AKID: AKIA... (now destroyed)
  New active AKID:  AKIA... (was secondary, now primary slot in TF state)
  New secondary AKID: AKIA... (freshly created)
  Affected consumers: <count> LXCs re-seeded automatically, <count> manually
  Issues: <none / list>
```

## Rollback

If rotation goes wrong mid-procedure (script crashes between step 2 and step 4 of the script):

- **Both keys still valid in IAM**: the legacy alias points at the new key. Consumers will pick it up. No rollback needed; just re-run from step 2 once the cause of the crash is fixed.
- **Old primary disabled, new key works for consumers but Terraform never applied**: this is a stable state. The next scheduled rotation will apply the pending `terraform taint` and create a fresh secondary. Optional: run `terraform apply` immediately to materialize the new secondary now.
- **Old primary disabled, new key fails for consumers**: AWS SDKs sometimes need a few minutes for `Inactive` to fully propagate AND for cached sessions to expire. Wait 10 minutes, retry. If still failing, run `aws iam update-access-key --status Active` to re-enable the old primary and abort the rotation. Investigate why the new key fails before retrying.

## Adversarial review findings codified here

Five concerns surfaced during the Phase B-1 design adversarial review; all are mitigated by either the existing Terraform shape, the script logic, or this runbook:

| # | Concern | Severity | Where mitigated |
|---|---------|----------|-----------------|
| 1 | New `pve-rotation-runner` IAM principal would defeat self-rotation prevention | risk | Rejected — use existing `sh1admn` admin profile (no new IAM user) |
| 2 | "Read both keys, fall back" cookbook redesign conflicts with merged alias design | blocker | Rejected — consumers continue reading the legacy alias only; rotation script handles the swap |
| 3 | `create_before_destroy = true` plus AWS 2-key cap could deadlock | risk | Script does `aws iam update-access-key --status Inactive` first, then `terraform taint` (out-of-band delete before TF re-create) |
| 4 | Cross-region SNS target may silently drop EventBridge → SNS messages | risk | Verify in step 4(d); if email never arrives, check `aws_sns_topic.alerts` policy allows `events.amazonaws.com` from `us-east-1` |
| 5 | `lifecycle ignore_changes = [value]` on alias means `terraform apply -replace` silently reverts rotation | risk | Documented in step 3 ("Trap") — never use `-replace` on alias resources without re-running rotation |

## Soak monitoring (during 30-day observation)

While Phase B-1 is in soak (one full rotation cycle = 30 days):

- After rotation, check the bootstrap-creds Prometheus metric daily for 3 days. Any host with `bootstrap_lxc_creds_last_result{result="failed"}` indicates the orchestrator's re-seed didn't pick it up cleanly. Investigate that host before trusting the next cycle.
- 30 days from rotation, schedule the next rotation (the previously-secondary slot is now the rotation candidate). Two consecutive successful 30-day cycles graduate B-1 from soak to "stable".
- If any rotation step requires manual intervention beyond what step 4 (verify) covers, write a TODO note on what the runbook didn't anticipate and update this document before the next cycle.
