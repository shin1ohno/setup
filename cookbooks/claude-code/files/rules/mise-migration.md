# Tool-Manager Migration Verification Protocol

When migrating a tool from Homebrew (or any system package manager) to **mise**, **direct download**, or any non-package-manager install path, the design phase is the highest-leverage place to catch upstream-fact bugs. Plan agents and web-search summaries give authoritative-sounding answers that are frequently wrong about specifier form, asset availability, tag prefix, and repo language. **Verify against the upstream's actual API before writing the cookbook.**

## When this rule fires

Apply this protocol whenever you are about to write any of these into a cookbook:

- `mise_tool "<name>"` (core registry use)
- `mise_tool "<slug>" do backend "<ubi|aqua|github|go|cargo|npm|pipx>" end`
- A `curl` + `tar`/`unzip`/`installer` block that fetches a pre-built binary from any URL
- A `shasum -c` block that consumes an upstream-supplied `.sha256` file
- An `installer -pkg` block sourced from a vendor distribution URL

## The 5-check verification batch

Run these in parallel (one batch per tool) **before** writing the cookbook lines:

```bash
# 1. mise core registry coverage — does bare `mise use <name>` work?
mise registry <name>          # returns backend prefixes if listed; errors otherwise

# 2. (For ubi:/github: backends) confirm tag format and asset availability
gh api repos/<owner>/<repo>/releases/latest \
  --jq '.tag_name, (.assets[] | .name)' | head -10

# 3. (For direct-download URLs) confirm 200 status without any UA / cookie
curl -fsI -A "Mozilla/5.0" "<url>" | head -3
# -f: fail on 4xx/5xx (don't silently save error body)
# -s: suppress progress meter
# -I: HEAD only (no body download)

# 4. (For .sha256 sidecar files) inspect the format
curl -s "<url>.sha256" | head -1
# `<hash>  <filename>`  → shasum -a 256 -c works as-is
# `<hash>` (bare)        → must build the line: printf '%s  %s\n' "$hash" "$filename" | shasum -c

# 5. (For go:/cargo:/npm: backends) confirm the repo's primary language
gh api repos/<owner>/<repo> --jq '.language'
# go: backend → must be Go. cargo: → Rust. npm: → JS/TS.
```

## Concrete failure modes this catches

PR #32 (2026-04-25 mitamae brew→mise migration) shipped 8 distinct upstream-fact bugs because this batch was skipped. Each one is invisible from web-search but obvious from the API:

| Bug pattern | Tool example (PR #) | What the check would have shown |
|---|---|---|
| `ubi:` prepends `v` to version, but upstream tag is bare `1.6.2` | xcodes (#33) | `gh api ... --jq '.tag_name'` returns `1.6.2`, not `v1.6.2` |
| `.sha256` is bare hash; `shasum -c` rejects | Tailscale (#34) | `curl -s ...sha256` returns one 64-char hex line, no filename |
| Arch-specific URL returns 403; only `-universal` works | Ookla speedtest (#36) | `curl -fsI ...arm64.tgz` returns HTTP 403 |
| GitHub release exists but assets array is empty | eternal-terminal (#37) | `gh api ... --jq '.assets'` returns `[]` |
| Tool is not in mise core registry | zk (#38) | `mise registry zk` errors `tool not found in registry` |
| Asset names lack `darwin`/`macos`/`osx` substring | aria2 (#41) | All assets end in `-linux-android`, `-win-64bit`, or `.tar.*` |
| Repo is Swift, not Go (so `go:` backend fails) | macism (#41) | `gh api repos/laishulu/macism --jq '.language'` returns `Swift` |
| `curl -L` (no `-f`) silently saves 4xx body to disk | speedtest (#36) | `curl -fsI` returns HTTP 403 → use `curl -fsSL`, never `curl -L` alone |

## How to apply

1. **Plan phase**: when listing tools to migrate, draft the verification batch alongside each tool. The skill `/verify-mise-backend` runs all 5 checks in parallel; invoke it before writing the cookbook diff.
2. **Write phase**: only write the cookbook line after the batch has confirmed: backend type / asset name / URL status / sidecar format / repo language. Annotate the cookbook with the verified upstream fact in a comment when it's non-obvious (`# ubi can't install this — only source tarball published`).
3. **Trust hierarchy**: `mise registry`, `gh api`, `curl -fsI` > Plan-agent output > web-search summaries. Never invert this.

## When NOT to apply

- Pure brew formula installs (no migration involved)
- Existing recipes you're only restructuring without changing the install path
- Internal tools / private registries (this protocol assumes public GitHub releases / vendor URLs)

## Anti-pattern: trusting plan-agent backend mappings without verification

A Plan agent may return: "xcodes → `ubi:XcodesOrg/xcodes`, aria2 → `ubi:aria2/aria2`, macism → `go:github.com/laishulu/macism`". Each mapping looks plausible but is wrong (tag format, no darwin asset, wrong language). The agent constructed the mappings from web-search summaries that did not include upstream API state. **Run the 5-check batch on each one before adopting.**
