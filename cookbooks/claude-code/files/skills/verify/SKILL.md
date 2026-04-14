---
name: verify
description: Run project tests, lint, and type checks to verify implementation correctness.
user-invocable: true
allowed-tools: ["Bash"]
argument-hint: "[scope]"
---

# Verify Skill

## Purpose

Verify that the current implementation is correct by running all available checks.

## Argument Parsing

`$ARGUMENTS` is an optional scope hint (e.g., a file path or feature name). If omitted, run all detected checks.

## Workflow

### Step 1: Detect Project Type

Check for these markers in order and run all matching checks:

| Marker | Check | Command |
|--------|-------|---------|
| `package.json` with test script | Tests | `npm test` |
| `package.json` with lint script | Lint | `npm run lint` |
| `tsconfig.json` | Type check | `npx tsc --noEmit` |
| `Gemfile` + `Rakefile` | Tests | `bundle exec rake test` |
| `Makefile` with test target | Tests | `make test` |
| `Cargo.toml` | Tests + Lint | `cargo test` then `cargo clippy` |
| `pyproject.toml` | Tests | `python -m pytest` |
| `pyproject.toml` + pytest-cov | Coverage | `python -m pytest --cov` |
| `go.mod` | Tests + Vet | `go test ./... -coverprofile=coverage.out` then `go vet ./...` |

### Step 1.5: Static Review (Design, Naming, Comments)

Launch a `code-reviewer` agent to scan the current diff (`git diff HEAD`) for issues that automated tools cannot catch:

- **Design**: does the change fit the system architecture? Are interfaces consistent with existing patterns?
- **Naming**: are new names clear, descriptive, and consistent with project conventions?
- **Comments**: do comments explain "why" rather than "what"? Are misleading comments flagged?

This step runs in parallel with Step 2 (automated checks).

### Step 2: Run Checks

Execute each detected check. Capture stdout and stderr.

### Step 3: Report

Output a summary table:

```
| Check      | Status | Details          |
|------------|--------|------------------|
| Tests      | PASS   | 42 passed, 0 failed |
| Lint       | FAIL   | 3 errors (see below) |
| Type check | PASS   |                  |
```

For failures, include the relevant error output (truncated to 50 lines per check).

### Step 4: UI Verification (if applicable)

If `$ARGUMENTS` mentions UI, frontend, or visual changes:
- Remind the user to check the result in a browser
- If the Chrome extension is available, suggest using it for screenshot comparison
