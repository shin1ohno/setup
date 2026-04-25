---
name: verify-mise-backend
description: Pre-migration verification for tools targeted at mise / direct-download installs. Runs the 5-check batch (mise registry, GitHub release tag + assets, URL HEAD, .sha256 format, repo language) for each tool before any cookbook line is written. Use BEFORE writing `mise_tool` / `backend "ubi|github|aqua|go|cargo"` / direct curl+install blocks. Trigger phrases - "verify mise backend", "check mise registry", "pre-migration check", "confirm tool specifier", "is X in mise", "does X have darwin asset". MUST be invoked when designing any Homebrew → mise migration or new external-binary-download cookbook entry.
---

# Verify Mise Backend Skill

## Purpose

Run a 5-check verification batch on each tool BEFORE writing its cookbook recipe. Catches the upstream-fact bugs (wrong tag prefix, missing darwin asset, bare-hash sidecar, wrong language) that web-search summaries miss.

This skill is the execution arm of the `mise-migration.md` rule. The rule says "always verify before writing"; this skill makes the verification cheap to run.

## Inputs

The user provides a list of tools to verify. For each tool, collect at minimum:

- `name`: short tool name (e.g. `xcodes`, `macism`, `tailscale`)
- `specifier` (optional): the planned mise specifier (e.g. `ubi:XcodesOrg/xcodes`, `go:github.com/laishulu/macism`, or `aqua:zk-org/zk`)
- `url` (optional): direct download URL if a non-mise install is being considered (e.g. `https://pkgs.tailscale.com/stable/Tailscale-1.96.5-macos.pkg`)

If the user lists only `name`, infer the most likely specifier and verify both that and the bare core-registry case.

## Workflow

For each tool, run all 5 checks in parallel. Report a pass/fail table with the exact observed value at each check.

### Check 1: mise core registry coverage

```bash
mise registry <name>
```

- **Pass**: returns one or more `backend:slug` lines (e.g. `aqua:sharkdp/fd asdf:... cargo:fd-find`). Bare `mise use <name>` will work.
- **Fail**: errors `tool not found in registry`. Need an explicit backend prefix.

### Check 2: GitHub release tag and asset audit

For `ubi:` / `github:` backend candidates, query the latest release:

```bash
gh api repos/<owner>/<repo>/releases/latest \
  --jq '.tag_name as $t | (.assets[] | "\($t) \(.name)")'
```

- **Pass**: tag format is what mise expects, AND asset names contain at least one of `darwin`, `macos`, `osx`, `aarch64`, `arm64`, `universal` (mise's github backend matches against these).
- **Common failures**:
  - Tag is `1.6.2` but ubi prepends `v` → 404 on `/releases/tags/v1.6.2` (use github: backend, not ubi:)
  - `assets` array is empty → no prebuilt binaries published; mise install will fail
  - All assets are linux/win/source only → no darwin support; revert to brew or different backend

### Check 3: Direct-download URL HEAD

For any URL referenced in a `curl` block:

```bash
curl -fsI -A "Mozilla/5.0" "<url>" | head -3
```

- **Pass**: HTTP 200 (or 302 redirect chain ending at 200).
- **Fail**: 403/404/5xx → URL is wrong, requires auth, or vendor-CDN-blocked. Do not write `curl -L "<url>"` blocks against this URL.

Note: always use `curl -fsSL` (not `curl -L` alone) in cookbooks — `-f` makes curl exit non-zero on HTTP errors instead of silently saving the error body.

### Check 4: `.sha256` sidecar format

For verified-download blocks:

```bash
curl -s "<url>.sha256" | head -1
```

- **Canonical format** (`<hash>  <filename>`): `shasum -a 256 -c <file>.sha256` works directly.
- **Bare hash** (just 64 hex chars, e.g. Tailscale): build the canonical line on the fly:
  ```bash
  printf '%s  %s\n' "$(cat <file>.sha256)" "<filename>" | shasum -a 256 -c -
  ```

### Check 5: Repo primary language (for `go:` / `cargo:` / `npm:` backends)

```bash
gh api repos/<owner>/<repo> --jq '.language'
```

- `go:` backend → must be `Go`
- `cargo:` backend → must be `Rust`
- `npm:` backend → must be `JavaScript` or `TypeScript`
- `pipx:`/`pip:` → must be `Python`

If the language doesn't match the planned backend, the install will fail. Switch to direct download from releases (Check 2's assets) or revert to brew.

## Output format

For each tool, produce a row:

```
<name> | mise registry: <result> | tag: <observed> | assets: <list or empty> | url: <HTTP status> | sha256 fmt: <bare|canonical|n/a> | language: <observed>
verdict: <PASS / FAIL with specific reason>
recommended specifier: <ubi:... | github:... | aqua:... | direct curl | brew>
```

End with a summary block: count of PASS vs FAIL, and a list of any FAIL tools with their failure reason.

## When this skill auto-invokes

The harness should match this skill against requests like:

- "verify mise can install <X>"
- "check if <X> is in mise registry"
- "confirm <X> has a darwin binary"
- "pre-migration check for <list>"
- "does this mise specifier work" / "is `ubi:foo/bar` valid"
- Any user message that contains an `ubi:` / `aqua:` / `github:` / `go:` / `cargo:` specifier alongside discussion of a planned migration

## Reference

Full failure-mode catalog and rationale: `~/.claude/rules/mise-migration.md`. PR #32 (2026-04-25 brew→mise) shipped 8 distinct bugs from skipping this protocol. PRs #33, #34, #36, #37, #38, #41 are the post-merge cleanup.
