# Rust Code Guidelines — Examples & Origin Notes

## crates-io-token-scopes

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

### Token allow-list must enumerate the transitive publishable closure

A workspace release publishes more than just the crates flagged `publish = true` in `release-plz.toml`. Cargo also publishes path-dependency crates of any published target — anything `cargo publish -p <root>` would push. Token allow-lists must include the full closure, not just the explicit publish targets.

When a release-plz run hits 403 on a crate that was previously published successfully (so it is not a publish-new case), the failure is almost always allow-list scope, not crate scope. Symptom: token allow-list lists the explicit publish targets but omits a workspace-internal crate that release-plz must also push because workspace-version inheritance bumps every member.

**Pre-merge checklist** for the auto-generated `chore: release vX.Y.Z` PR:

1. Read the `[[package]] name = "..."` entries in `release-plz.toml` (the explicit publish set)
2. `grep -l '^name = ' crates/*/Cargo.toml` — list every workspace crate
3. For each workspace member without `publish = false` in its `Cargo.toml`, confirm it appears in the token's allow-list at https://crates.io/settings/tokens
4. If any are missing, re-issue the token with the expanded allow-list **before** merging the release PR

Origin: 2026-04-25 v0.5.4 — two consecutive release 403s because edge-core and weave-ios-core were omitted from the token allow-list.

**Workspace-internal crates that should be `publish = false`**: if a crate is genuinely internal (e.g. `weave-ios-core` — UniFFI binding for one specific app, "Not intended for non-Swift consumers" per its description), set `publish = false` in its `Cargo.toml` rather than adding it to the token allow-list. release-plz will then skip it cleanly. Reserve allow-list entries for crates that genuinely ship to crates.io.
