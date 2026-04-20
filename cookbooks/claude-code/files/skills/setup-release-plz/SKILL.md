---
name: setup-release-plz
description: Scaffold release-plz CI + config for a Rust repo on GitHub. Adds the CI workflow, release-plz.toml, enables Actions PR permissions, and guides the CARGO_REGISTRY_TOKEN setup. Use when onboarding a new Rust repo to auto-release via release-plz, or when fixing a repo whose release-plz is failing on a known misconfiguration.
user-invocable: true
---

# /setup-release-plz

Scaffold release-plz CI + config for a Rust repo that should auto-publish to crates.io on every main push. Captures the known-good pattern extracted from nuimo-rs / edge-agent / weave / roon-rs — all four of which converged on the same shape after repeated debugging.

## When to use

- Onboarding a new Rust repo to crates.io auto-publish
- A repo's existing release-plz is failing — run this to re-align with the reference setup before deeper debugging
- Any `/release-plz.md` rule checkbox is missing in a repo

## Prerequisites (check before scaffolding)

1. Target repo has at least one publishable crate (`publish = true` in Cargo.toml, or absence of `publish = false`)
2. User has a crates.io API token ready, OR is willing to issue one. Scope needed: `publish-update` minimum, `publish-new` if the workspace has any never-published crate

## Workflow

### Step 1: Inspect current state

Run these in the target repo to find what's missing:

```
cd <repo>
ls .github/workflows/release-plz.yml 2>&1
cat release-plz.toml 2>&1
gh secret list --repo <owner>/<repo> | grep -i cargo
gh api repos/<owner>/<repo>/actions/permissions/workflow
grep -rn 'path = "' crates/*/Cargo.toml
```

Compile findings into a checklist matching `rules/release-plz.md`.

### Step 2: Scaffold files

Create or update these files. Use the existing files in `~/ManagedProjects/nuimo-rs/` or `~/ManagedProjects/edge-agent/` as templates — their workflows are the known-good reference.

**`.github/workflows/release-plz.yml`** (minimum fields):
- Trigger: `push: branches: [main]` + `workflow_dispatch`
- Two jobs: `release-plz-release` (runs first), `release-plz-pr` (`needs: release-plz-release`)
- Both use `MarcoIeni/release-plz-action@v0.5.128` (pin to a concrete tag, NEVER `@v0`)
- Both set `CARGO_REGISTRY_TOKEN: ${{ secrets.CARGO_REGISTRY_TOKEN }}` and `GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}`
- Top-level `permissions: contents: write, pull-requests: write`
- Install any system deps the crate needs (Linux BLE via `libdbus-1-dev pkg-config`, TLS via `libssl-dev`, etc.) in both jobs

**`release-plz.toml`** (workspace + per-package):
```toml
[workspace]
changelog_update = true
pr_branch_prefix = "release-plz/"

[[package]]
name = "<crate-1>"
publish = true

[[package]]
name = "<crate-2>"
publish = false    # internal / library meant for workspace-only
release = false    # suppress tag + changelog too
```

For every publishable crate, ensure its `Cargo.toml` has: `description`, `license`, `repository`, `keywords`, `categories`, `readme`.

For every path dep across the workspace: add `version = "X.Y"` fallback.

### Step 3: Set repo-level GitHub Actions permissions

```
gh api -X PUT repos/<owner>/<repo>/actions/permissions/workflow \
  -f default_workflow_permissions=write \
  -F can_approve_pull_request_reviews=true
```

### Step 4: Register `CARGO_REGISTRY_TOKEN` secret

Use AskUserQuestion to collect the token value (user supplies it, paste into chat), then:

```
gh secret set CARGO_REGISTRY_TOKEN --repo <owner>/<repo> --body '<token>'
```

If this is a workspace with a never-published crate, surface the `publish-new` scope requirement from `rules/rust.md` and ask the user whether to handle the first publish via a one-off token path.

### Step 5: Verify

1. Run `cargo publish -p <crate> --dry-run --allow-dirty` locally for each publishable crate to surface any packaging issues before the CI run
2. Commit the scaffolded files on a branch and open a PR (`gh pr create`). Do not push to main directly
3. After PR merge: check the release-plz run completed green — both `release` and `release-pr` jobs success

### Step 6: Record the setup in TODO.md / Cognee

If the repo is part of an ecosystem tracked in memory, note the setup completion with:

- Repo URL
- `CARGO_REGISTRY_TOKEN` scope + allow-list
- Any special system deps
- Any baseline-commit issues remaining (e.g., "0.1.0 has broken Cargo.toml.orig; bump to 0.1.1 to migrate baseline")

## Reference files

- `rules/release-plz.md` — checklist of all 8 failure modes + pre-flight checklist
- `rules/rust.md` — token scope section (`publish-update` vs `publish-new`)
- `~/ManagedProjects/nuimo-rs/.github/workflows/release-plz.yml` — current-generation reference
- `~/ManagedProjects/edge-agent/.github/workflows/release-plz.yml` — same shape

## Anti-patterns

- Skipping Step 3 (workflow permissions) — release-plz-pr job fails silently with 403 until fixed
- Omitting `needs: release-plz-release` — race condition on first push with version bump (documented in `rules/release-plz.md`)
- Adding a new publishable crate to an existing setup without updating the token's allow-list — 403 on first publish
- Using `MarcoIeni/release-plz-action@v0` — tag does not exist; must be a concrete `@v0.5.X`
