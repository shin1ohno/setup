# Ruby Code Guidelines

- Prefer explicit over implicit — avoid magic methods and meta-programming unless clearly beneficial
- Use guard clauses to reduce nesting
- Follow existing project conventions (indentation, naming, etc.)
- When working with mitamae DSL: use `not_if` / `only_if` for idempotency checks
- Prefer symbols over strings for hash keys in DSL code
- mitamae runs without sudo. Never use `owner node[:setup][:system_user]` on file/remote_file resources — it triggers an internal `sudo chown` that fails without a terminal. Instead, stage files in user space (`node[:setup][:root]`) and use `execute` with explicit `sudo cp` to place them in system directories

# Rust Code Guidelines

- Error handling: `thiserror` in library crates, `anyhow` in binary crates
- Async runtime: tokio
- Prefer `cargo clippy --workspace --tests` over `cargo clippy` alone

## Commit Gate for Rust Projects

Before every git commit in a Rust workspace, run all three checks:
1. `cargo build --workspace`
2. `cargo test --workspace`
3. `RUSTFLAGS="-D warnings" cargo clippy --workspace --tests` — must be warning-free. Matches CI's flags; catches `dead_code` and other lints that bare `cargo clippy` surfaces only as warnings (e.g. a parametric helper committed ahead of its runtime caller)

Do not commit if any check fails. Fix the issue first.

## Verify Step Side Effects

`cargo build`, `cargo test`, and `cargo clippy` regenerate `Cargo.lock` in
place when versions or dependencies change. Any skill or multi-step script
that runs these commands as a verify step MUST include `Cargo.lock` in the
subsequent `git add`. Omitting it produces a commit where `Cargo.toml` and
`Cargo.lock` are out of sync — broken for downstream consumers and
`cargo publish` dry-runs.

General rule: before writing the "stage changes" step of a skill, list every
file the verify commands can touch as a side effect and include all of them
in the `git add` pattern.

## crates.io Token Scopes — publish-new vs publish-update

crates.io API tokens have per-action scopes. For release-plz / manual publishing:

- **`publish-update`**: version bump of an EXISTING crate (most common day-to-day)
- **`publish-new`**: the FIRST publish of a new crate name. Required even if the crate is listed in the token's allow-list — `publish-update` is NOT sufficient for the first push
- **`yank`**: separate scope, only needed when retracting a published version

The trap: when adding a new publishable crate to a workspace that already has a `CARGO_REGISTRY_TOKEN` secret (with `publish-update` scope), the first release-plz run on that crate fails with:

```
error: failed to publish <crate> v0.1.0 to registry at https://crates.io
Caused by:
  the remote server responded with an error (status 403 Forbidden): this token does not have the required permissions to perform this action
```

crates.io does NOT allow editing an existing token's scope; you must revoke and re-issue.

**Practical workflow** when adding a new publishable crate:

1. Issue a one-off token with **just `publish-new` scope** + allow-list = the new crate name
2. `cargo publish -p <new-crate> --token <one-off-token>` to do the first publish manually from HEAD
3. Revoke the one-off token
4. Future version bumps use the existing `publish-update` token via release-plz — no further action needed

Alternatively, re-issue the main `CARGO_REGISTRY_TOKEN` with both `publish-new` + `publish-update` scopes if you add new crates often. Update the secret in every repo using it (`gh secret set CARGO_REGISTRY_TOKEN`).

## Pre-`/bump-version` Sanity Check

Before invoking `/bump-version`, confirm `git status` shows no unstaged
changes (or only intentional ones). The verify step's lockfile rewrite will
otherwise tangle with unrelated edits, making the resulting commit hard to
review and easy to mis-stage. Stash or commit work-in-progress first.
