---
name: setup-release-plz
description: Scaffold release-plz CI + config for a Rust repo on GitHub. Adds the CI workflow, release-plz.toml, enables Actions PR permissions, and sets up crates.io trusted publishing (a one-off token only for a never-published crate). Use when onboarding a new Rust repo to auto-release via release-plz, or when fixing a repo whose release-plz is failing on a known misconfiguration.
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
2. The user can open each crate's crates.io settings to add a trusted publisher. A never-published crate additionally needs a one-off `publish-new` token for its first publish

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

Compile findings into a checklist matching `docs/release-plz.md`.

### Step 2: Scaffold files

Create or update these files. Use the existing files in `~/ManagedProjects/nuimo-rs/` or `~/ManagedProjects/edge-agent/` as templates — their workflows are the known-good reference.

**`.github/workflows/release-plz.yml`** (minimum fields):
- Trigger: `push: branches: [main]` + `workflow_dispatch`
- Two jobs: `release-plz-release` (runs first), `release-plz-pr` (`needs: release-plz-release`)
- Both use `release-plz/action` pinned by full commit SHA with the tag as a comment (`release-plz/action@<sha> # v0.5.148`; resolve with `gh api repos/release-plz/action/commits/<tag> --jq .sha`). Never `@v0`
- Top-level `permissions: {}`; `release-plz-release` gets `contents: write` + `id-token: write` and `environment: crates-io`; `release-plz-pr` gets `contents: write` + `pull-requests: write`
- Crates that already exist on crates.io publish through **trusted publishing**: no `CARGO_REGISTRY_TOKEN` in the workflow and no `rust-lang/crates-io-auth-action` — release-plz exchanges the OIDC token itself (`docs/release-plz.md#trusted-publishing`). Both jobs set `GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}` in `env:`
- No cache restore (`Swatinem/rust-cache`) in either job; `actions/checkout` with `fetch-depth: 0`
- `timeout-minutes` on both jobs
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
  -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=true
```

The default token stays read-only; the jobs get write access through their own `permissions:` blocks.

### Step 4: Set up crates.io publishing

**Existing crates — trusted publishing.** For every published crate, the user adds a trusted publisher on crates.io (crate → Settings → Trusted Publishing: owner `<owner>`, repo `<repo>`, workflow `release-plz.yml`, environment `crates-io`). Create the `crates-io` environment on the repo (`gh api -X PUT repos/<owner>/<repo>/environments/crates-io`). No secret is needed. Once every crate is covered, delete any old `CARGO_REGISTRY_TOKEN` secret and ask the user to revoke the token on crates.io.

**Never-published crates.** Trusted publishing cannot create a crate. Ask the user (use a question tool if one is available, otherwise write numbered options in the body; Claude Code: AskUserQuestion / Codex: request_user_input) how to do the first publish: a one-off `publish-new` token used locally (`cargo publish -p <crate> --token …`, then revoke — `docs/release-plz.md#crates-io-token-scopes`), after which the trusted publisher is configured and release-plz takes over.

### Step 5: Verify

1. Run `cargo publish -p <crate> --dry-run --allow-dirty` locally for each publishable crate to surface any packaging issues before the CI run
2. Commit the scaffolded files on a branch and open a PR (`gh pr create`). Do not push to main directly
3. After PR merge: check the release-plz run completed green — both `release` and `release-pr` jobs success

### Step 6: Record the setup in TODO.md / the memory MCP

If the repo is part of an ecosystem tracked in memory (when a memory MCP is available), note the setup completion with:

- Repo URL
- `CARGO_REGISTRY_TOKEN` scope + allow-list
- Any special system deps
- Any baseline-commit issues remaining (e.g., "0.1.0 has broken Cargo.toml.orig; bump to 0.1.1 to migrate baseline")

## Reference files

- `docs/release-plz.md` — checklist of all 8 failure modes + pre-flight checklist
- `docs/rust.md` — token scope section (`publish-update` vs `publish-new`)
- `~/ManagedProjects/nuimo-rs/.github/workflows/release-plz.yml` — current-generation reference
- `~/ManagedProjects/edge-agent/.github/workflows/release-plz.yml` — same shape

## Anti-patterns

- Skipping Step 3 (workflow permissions) — release-plz-pr job fails silently with 403 until fixed
- Omitting `needs: release-plz-release` — race condition on first push with version bump (documented in `docs/release-plz.md`)
- Adding a new publishable crate to an existing setup without updating the token's allow-list — 403 on first publish
- Using `release-plz/action@v0` (or any tag reference) — `@v0` does not exist, and a movable tag is a supply-chain hole; pin the commit SHA
- Keeping `CARGO_REGISTRY_TOKEN` in the workflow after trusted publishing is configured — the stored token keeps the long-lived credential alive for no benefit
