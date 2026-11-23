# Rust Code Guidelines

Load when committing / building / publishing in a Rust workspace (a repo with `Cargo.toml`), or when `pr-ci-medic` repairs a Rust repo's CI. Demoted from always-loaded `rules/` 2026-07 (claude-md-audit: 1/240 sessions touched Rust in 30 days; the frontmatter `globs` gating never worked). The crates.io token-scope examples + origin notes live in `~/.claude/docs/release-plz.md#crates-io-token-scopes`.

## Commit Gate for Rust Projects

Before every git commit in a Rust workspace, run all four checks in order:
0. `cargo fmt --check --all` — must produce no diff. Run first; it's the fastest failure to fix. Matches CI's rustfmt step. A multi-import line-break or brace-style mismatch that passes clippy will still fail CI if fmt is skipped. Origin: 2026-04-23 weave — fmt failed CI after clippy + test + build were green
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

Detail (403 trap + practical workflow + transitive-closure allow-list checklist + origin): see `~/.claude/docs/release-plz.md#crates-io-token-scopes`.

## tls-roots
## TLS Root Store — trust the OS, not a compiled-in set

A root set compiled into the binary (`webpki-roots`, `webpki-root-certs`) changes only on rebuild, so distrust of a compromised CA reaches the OS but not the binary.

- reqwest 0.12: `rustls-tls-native-roots`, never `rustls-tls` (webpki-roots only). Enabling both trusts both sets.
- reqwest 0.13: the `rustls` feature (rustls-platform-verifier); do not enable its `webpki-roots` / `rustls-native-certs` leftovers.
- Other crates: prefer `rustls-platform-verifier`, then `rustls-native-certs`, over `with_webpki_roots()` constructors. Dependencies with TLS defaults (`oauth2`, `openidconnect`) enable `reqwest/rustls-tls` — set `default-features = false`.
- **iOS / Android are the exception for native-certs**: `rustls-native-certs` treats iOS as generic unix and probes OpenSSL file paths that do not exist there, so the store comes back empty (`rustls-native-certs` `src/lib.rs` cfg branches). On mobile use `rustls-platform-verifier` (reqwest 0.13 `rustls`, or 0.12 `use_preconfigured_tls` with a platform-verifier `ClientConfig`); keep `rustls-tls` until that migration is verified on a device.
- The runtime image must ship a CA bundle: `debian:*-slim` needs `ca-certificates`; `scratch` / distroless-static need one copied in.
- Verify: `cargo tree -e features -i webpki-roots` (and `-i webpki-root-certs`) shows no path from the crates you changed.
- A client built with `danger_accept_invalid_certs(true)` (e.g. a LAN appliance with a self-signed cert) is unaffected by the root store; that is a separate trust decision.
- A deliberate compiled-in set with an operator override (e.g. `SSL_CERT_FILE` replacing the WebPki roots) is a design choice — leave it and say so where the client is built.

## Pre-`/bump-version` Sanity Check

（`/bump-version` は roon-rs 等の project skill — global には存在しない。）

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

Origin: 2026-04-23 iOS — marked `weave-ios-core` complete on green Linux build while the Mac-side `xcodebuild -create-xcframework` exit criterion was unrun.

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

Origin: 2026-04-23 iOS — `build-xcframework.sh` lacked a rustup-target guard; user hit `E0463 can't find crate for core`.
