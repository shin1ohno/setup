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

Before every git commit in a Rust workspace, run all four checks in order:
0. `cargo fmt --check --all` — must produce no diff. Run first; it's the fastest failure to fix. Matches CI's rustfmt step. A multi-import line-break or brace-style mismatch that passes clippy will still fail CI if fmt is skipped — caught this exact failure in the 2026-04-23 weave session after clippy + test + build were all green
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

## Cross-Platform Build Tasks — Completion Gate

When a Rust task targets a non-Linux platform (iOS, macOS-only, Android, WASM) and the verification must run on a host the current machine cannot emulate:

1. Mark the task `in_progress` — NOT `completed` — after the Linux-side code is committed
2. State "Exit criteria: [target host] で [specific observation]" in the status summary sent to the user
3. Completion requires observable evidence *from the target host*: xcframework file listing, `swiftc` compile output, device log, etc. A green `cargo build --workspace` on Linux is necessary but not sufficient
4. If the target host is unavailable this session, write a TODO.md entry with the exact verification command and keep the task `in_progress`; do not silently mark completed

This rule exists because the 2026-04-23 iOS session marked `weave-ios-core` (Phase 2) as `completed` after Linux-side build/test passed, but the plan's exit criteria required a Mac-side `xcodebuild -create-xcframework` that had not run. The user caught it with "Phase 2 は終わってますか？" — a false completion that would have silently propagated into downstream phase scheduling.

## Cross-Platform Build Scripts — Precondition Guard

When generating a build script that requires non-default rustup targets or toolchain components (`rustup target add …`, `cargo install <bin>`, system SDKs, env vars), always add a self-diagnosing guard at the top of the script:

```bash
for target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
  if ! rustup target list --installed | grep -q "^$target\$"; then
    echo "ERROR: missing rustup target: $target" >&2
    echo "Run: rustup target add $target" >&2
    exit 1
  fi
done
```

A prose handoff note ("初回のみ rustup target add してください") is NOT a substitute. Scripts are executed directly; documentation is sometimes skipped. The script must self-diagnose and output the exact remediation command as its error message.

Applies equally to: homebrew packages, required cargo binaries, first-run Xcode setup (`xcodebuild -runFirstLaunch`), env vars the build consumes.

This rule exists because the 2026-04-23 iOS session's `build-xcframework.sh` did not check `rustup target list --installed`; the user hit `E0463 can't find crate for core` on first run and had to decode which targets were missing from the cargo error rather than from a script-owned message.
