# release-plz Failure Mode Checklist

release-plz failures are almost always one of a small, recurring set of misconfigurations. When a `release-plz` workflow run fails, or before setting up release-plz on a new repo, scan this list **before reactive debugging**. Each item took real session time to diagnose; fixing upfront is 1-2 minutes, diagnosing from a red CI is 10-30.

## Secret presence

- **`CARGO_REGISTRY_TOKEN` is set on the repo** (`gh secret list --repo <owner>/<repo>` shows it). The workflow reads `${{ secrets.CARGO_REGISTRY_TOKEN }}` — missing secret → `cargo publish` fails with 403 "unauthorized"
- **Token scope matches the action**:
  - `publish-update` for existing crates getting a version bump
  - `publish-new` for the **first-ever publish** of a new crate name. Without this, first publish fails with `403 Forbidden: this token does not have the required permissions`
  - crates.io does NOT allow editing an existing token's scope — revoke + re-issue
- **Token allow-list includes the crate being published**. When adding a new crate, the existing token's allow-list must be extended (= re-issued)

## Workflow metadata

- **Action version tag exists**: `MarcoIeni/release-plz-action@v0` has never existed. Use a concrete tag like `@v0.5.128`. A non-resolving tag fails the run with `Unable to resolve action ..., unable to find version v0`
- **Repo-level workflow permissions allow PR creation**:
  ```
  gh api repos/<owner>/<repo>/actions/permissions/workflow
  # default_workflow_permissions must be "write"
  # can_approve_pull_request_reviews must be true
  ```
  Default is `read` / `false`. Fix:
  ```
  gh api -X PUT repos/<owner>/<repo>/actions/permissions/workflow \
    -f default_workflow_permissions=write \
    -F can_approve_pull_request_reviews=true
  ```
  Without this, `release-pr` fails with `403 Forbidden` when creating the release PR

## Job serialization

- **`release-pr` job has `needs: release-plz-release`** (or equivalent). Without it, on a version-bump push the two jobs race: `release-pr` queries crates.io BEFORE `release` finishes publishing, sees the OLD baseline, and may hit historical-commit issues

## Workspace / Cargo.toml shape

- **Every path dep must also have a `version`**. `edge-core = { path = "../edge-core" }` fails `cargo package` with `dependency X does not specify a version`. Use `edge-core = { path = "../edge-core", version = "0.1" }` so packaging can record the registry fallback
- **No path deps to OTHER repos**. `weave-contracts = { path = "../../../edge-agent/crates/weave-contracts" }` embeds a filesystem path that release-plz's temporary checkout cannot resolve. Use crates.io registry with `version = "0.1"`
- **Published baseline commit must be cargo-metadata-clean**. If a prior bad publish left a `Cargo.toml.orig` with broken path deps on crates.io, release-plz's "package equality check" git-checkouts that baseline commit and runs `cargo metadata` — which fails if the commit has unresolvable path deps. Fix by bumping the affected crate to a new version whose baseline commit is clean, then manually publishing

## release-plz.toml shape

- Every publishable crate has `publish = true` explicitly, or omits the block (default is publish from crate's `Cargo.toml`)
- Every non-publishable crate has `publish = false` AND `release = false` — `release = false` suppresses the changelog / tag / PR for that crate too
- `semver_check = true` is fine on normal repos, but disable it (`semver_check = false`) if the workspace has a broken baseline commit and you cannot fix via a version bump

## First-publish gotcha

When adding a new publishable crate to a workspace with existing release-plz CI:

1. The repo's `CARGO_REGISTRY_TOKEN` likely does NOT have `publish-new` scope
2. release-plz's auto-publish will 403 on the first-ever publish of that crate
3. Workaround: manually `cargo publish -p <new-crate>` with a one-off `publish-new`-scope token. Subsequent version bumps use the normal token

## Pre-flight checklist (copy into PR description)

```
- [ ] CARGO_REGISTRY_TOKEN set on repo
- [ ] Token scope covers this action (publish-new for first publish, publish-update for bumps)
- [ ] Token allow-list includes the crate names in this workspace
- [ ] release-plz-action@v* tag resolves (not @v0 / @v1)
- [ ] Repo workflow permissions: write + can_approve_pull_request_reviews
- [ ] release-pr job has `needs: release-plz-release`
- [ ] All path deps have version fallback
- [ ] No cross-repo path deps
- [ ] Baseline commit for each publishable crate's current published version is cargo-metadata-clean
```
