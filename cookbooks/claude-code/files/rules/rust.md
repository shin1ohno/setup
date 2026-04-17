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
3. `cargo clippy --workspace --tests` — must be warning-free

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

## Pre-`/bump-version` Sanity Check

Before invoking `/bump-version`, confirm `git status` shows no unstaged
changes (or only intentional ones). The verify step's lockfile rewrite will
otherwise tangle with unrelated edits, making the resulting commit hard to
review and easy to mis-stage. Stash or commit work-in-progress first.
