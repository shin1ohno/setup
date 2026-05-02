# Disk Hygiene

When working in environments where dev caches accumulate (Cargo, Python uv/pip, npm, browser test harnesses, container builds), proactively check disk pressure at appropriate moments and propose cleanup before it becomes a blocker.

## Pre-Heavy-Build Disk Check

Before invoking a command that will consume significant disk:

- `cargo build|test|install|run` on any non-trivial workspace
- `docker build` / `docker compose up --build`
- `npm run build` / `next build` / `vite build` for production
- `terraform plan|apply` against infrastructure that pulls providers/modules
- `pip install` / `uv sync` against a lockfile with many wheels

Run `df -h .` (1 second). If root or home filesystem is **>85% used**, pause and propose cleanup via AskUserQuestion before starting the task. The cost of a build aborting at 100% disk is far higher than the 1-second probe.

## Stale Cargo Target Detection

When the user mentions disk space / capacity / cleanup, OR when any single `target/` directory exceeds **20 GB** during a routine survey, run a stale-target audit:

```sh
for d in ~/ManagedProjects/*/target; do
  size=$(du -sh "$d" 2>/dev/null | cut -f1)
  mtime=$(stat -c '%y' "$d" 2>/dev/null | cut -d' ' -f1)
  echo "$mtime  $size  $d"
done | sort
```

For any `target/` untouched **>30 days** AND **>10 GB**, propose `cargo clean` (or `rm -rf <target>`) via AskUserQuestion.

## Cleanup Categories Template

When proposing cleanup, group by recovery cost:

| Category | Path | Recovery cost |
|---|---|---|
| Cargo target | `<project>/target/` | next `cargo build` (10-30 min initial) |
| Python pkg cache | `~/.cache/uv`, `~/.cache/pip` | next `uv sync` / `pip install` |
| npm pkg cache | `~/.npm/_cacache`, `~/.npm/_npx` | next `npm install` / `npx` |
| Browser test runners | `~/.cache/ms-playwright`, `~/.cache/puppeteer` | next test setup |
| Cargo registry index | `~/.cargo/registry` | next `cargo` invocation |
| Old rustup toolchains | `~/.rustup/toolchains/<version>` | `rustup toolchain install <version>` if needed |

**Before deleting rustup toolchains**: check `RUSTUP_TOOLCHAIN` env var (`rustup show active-toolchain`) and any `rust-toolchain.toml` pins in active projects. The active toolchain MUST stay. Most-recent stable / nightly usually stays too.

**Permission boundary**: `rm -rf` under `$HOME` is sometimes blocked by harness permissions. When blocked, present each cleanup command prefixed with `!` per the "Blocked Command Boundary" rule in `infrastructure.md` — never silently abandon the cleanup.

## Long-Term Mitigation

If the same project's `target/` repeatedly exceeds 20 GB, propose one of:

1. **Shared `CARGO_TARGET_DIR`** — `export CARGO_TARGET_DIR=$HOME/.cache/cargo-target` in `~/.zshenv` consolidates all Rust projects into one tree, deduplicating shared deps. Caveat: feature-flag conflicts cause rebuild churn
2. **`sccache`** — rustc-level shared cache. Less invasive than shared CARGO_TARGET_DIR
3. **`debug = "line-tables-only"` in dev profile** — reduces `target/` size 30-40% while keeping debugger-usable symbols
4. **Periodic `cargo clean`** — on projects untouched for >30 days

## Origin

This rule exists because the 2026-05-02 session hit 100% disk usage (916 GB / 6.4 GB free) during normal work, traceable to ~111 GB of accumulated `~/ManagedProjects/*/target` directories across 5 Rust workspaces. A pre-build `df` probe at any prior session would have surfaced the pressure before it reached a blocker; a stale-target audit on user mention of "余分なファイル" would have caught it earlier.
