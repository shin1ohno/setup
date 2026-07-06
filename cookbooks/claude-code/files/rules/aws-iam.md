---
description: "AWS IAM / SSM / Terraform operational rules — perpetual drift, SSM path constraints, IAM self-rotate, STS refresh, terraform branch gate, stale state lock"
---

# AWS IAM / SSM / Terraform Operational Rules

This file is the always-loaded summary. Long examples + origin notes are in `~/.claude/docs/aws-iam-detail.md` (NOT auto-imported — load on demand via Read tool when a section pointer matches the current task).

## Perpetual Drift Decision Framework

The same `terraform plan` diff surviving a successful apply — especially one marked `forces replacement` — is perpetual drift, not a glitch; every apply then replaces real resources to chase a cosmetic discrepancy. Trigger on the diff persisting after one apply, and pick a fix *before* the next apply in this order of preference: **A.** redesign away the pressure point → **B.** suppress the drift at its source (change the parent setting: `map_public_ip_on_launch`, VPC/launch-template defaults) → **C.** match reality in the config → **D.** `lifecycle.ignore_changes` (last resort — it hides future *real* drift, so always comment *why*).

Detail (full decision flow + common cosmetic-drift attribute table + origin): see `~/.claude/docs/aws-iam-detail.md#perpetual-drift-decision-framework`.

## Terraform Apply Branch Gate

Before invoking `terraform apply`, run `git branch --show-current` and confirm the branch is `main` (or the repo's designated deploy branch). On a feature branch, do NOT apply — present it as `! cd /absolute/path/to/repo && terraform apply -target=<scope>` for the user; applying unmerged changes bypasses the review gate (PR merge → pull `main` → apply is the correct sequence). Post-apply, run `terraform validate` to catch a resource-name-duplicated working tree left by a stash/pop or manual revert (surfaces only on the next operation otherwise).

Detail (feature-branch rationale + post-apply sanity check + `Duplicate ... configuration` recovery + origins): see `~/.claude/docs/aws-iam-detail.md#terraform-apply-branch-gate`.

## AWS SSM Parameter Path Constraints

Before writing any `aws_ssm_parameter` Terraform resource or `aws ssm put-parameter` cookbook call, confirm the path is not in a reserved namespace: `/aws`, `/AWS`, and `/ssm` prefixes are blocked at the API level (`AccessDeniedException: No access to reserved parameter name`) — the error fires at *apply* time, not plan, and Terraform shows no diff. Prefer project-scoped prefixes (`/<project>/<purpose>/...`, e.g. `/home-monitor/iam/<user>/<key-name>`).

Detail (pre-plan PUT+DELETE probe + full reserved-prefix list + origin): see `~/.claude/docs/aws-iam-detail.md#ssm-parameter-path-constraints`.

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

A `kms:Decrypt` grant for SSM SecureString reads MUST match the `kms:EncryptionContext:PARAMETER_ARN` StringLike condition with an **explicit account ID** (`${data.aws_caller_identity.current.account_id}`) and region — a wildcard `arn:aws:ssm:*:*:parameter/...` is rejected by KMS's evaluator, so every Decrypt fails with the misleading `AccessDeniedException: ciphertext refers to a customer master key that does not exist` (the error never names the unmet condition). Never wildcard the region either; enumerate each region explicitly.

Detection: an IAM role that should have `kms:Decrypt` is denied on every SecureString `GetParameter --with-decryption` — `aws iam get-role-policy ... --query 'PolicyDocument.Statement[?contains(Action, kms:Decrypt)]'` and look for `*:*:parameter/...` ARNs in the EncryptionContext condition. Detail (wrong/right HCL + full detection + origin): see `~/.claude/docs/aws-iam-detail.md#kms-decrypt-encryptioncontext`.

## Tailscale OAuth client scope — UI/API divergence requires API-side verification

Detail: see `~/.claude/docs/aws-iam-detail.md#tailscale-oauth-ui-divergence`.

## Reusable Tailscale auth keys for ephemeral compute

Detail: see `~/.claude/docs/aws-iam-detail.md#reusable-tailscale-keys`.

## Cost Table Labeling Conventions

Detail: see `~/.claude/docs/aws-iam-detail.md#cost-table-labeling`.

## KMS request attribution — query ssm:GetParameter, not kms:Decrypt

Detail: see `~/.claude/docs/aws-iam-detail.md#kms-attribution-query`.
