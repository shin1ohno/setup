# GitHub Actions — Supply-Chain Baseline

Load when creating, editing or reviewing a workflow under `.github/workflows/`, or when a loop (self-heal, pr-ci-medic, a CoS worker) is about to change one. Adapted from sorah/config `sorah-guides/skills/github-ci`.

## pinning
## Pin every remote action by commit SHA

```yaml
- uses: actions/checkout@<40-hex commit SHA> # v5.0.0
```

- Full 40-hex **commit** SHA, then one space, `#`, one space and the full semver tag. Local `./` actions and reusable workflows in the same repo are exempt. House style: `ai-memory/.github/workflows/ci.yml`, `session-search/.github/workflows/ci.yml`.
- Pin with pinact: `mise x aqua:suzuki-shunsuke/pinact -- pinact run` (uses `GITHUB_TOKEN`). By hand, resolve in this order:
  1. `gh api repos/<owner>/<repo>/commits/<ref> --jq .sha` — the commits endpoint takes a tag or a branch and dereferences annotated tags (`git/ref/tags/<tag>` returns the tag object's SHA for an annotated tag, which is wrong, and 404s for a branch such as `ruby/setup-ruby@v1`).
  2. For the comment, pick the semver tag that points at the same commit (`gh api repos/<o>/<r>/tags --paginate --jq '.[] | select(.commit.sha=="<sha>") | .name'`).
  3. Follow renames: `gh api repos/<old-owner>/<old-repo> --jq .full_name` (`MarcoIeni/release-plz-action` is `release-plz/action`). Pin the current name.
- **Refs that select behavior by name.** `dtolnay/rust-toolchain@stable` / `@nightly` / `@1.85` are branches; the action has one tag, `v1`, whose `toolchain` input is required. Pin `dtolnay/rust-toolchain@<sha> # v1` and add `with: { toolchain: stable }` on every step — pinning without the input fails every Rust job at input parsing.
- **Tools an action downloads at run time** are a second pin: `goreleaser/goreleaser-action` `version:`, `golangci/golangci-lint-action` `version:`, `zizmorcore/zizmor-action` `version:` default to `latest`. Set an exact version, above all in a job holding a signing key or a write token.
- Container actions (`docker://image`) pin the digest: `docker://rhysd/actionlint@sha256:<digest>`.

## dependabot
## Keep pins current with Dependabot

`.github/dependabot.yml`:

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: monthly
    cooldown:
      default-days: 7
    groups:
      actions:
        update-types: [minor, patch]
```

- Dependabot rewrites both the SHA and the trailing version comment. One grouped PR per repo per month; it touches `.github/workflows`, so it merges through the web UI (the gh token has no `workflow` scope).
- **Dependabot PRs get no repository secrets.** A job that needs one (an OIDC role ARN, an API key) is skipped for them — `if: github.event.pull_request.user.login != 'dependabot[bot]'` — or the monthly PR stays red. Do not copy secrets into Dependabot secrets: the bumped third-party code would run with them.
- A generated workflow is excluded: `exclude-paths: [".github/workflows/release.yml"]` under the entry (see `generated`).

## permissions
## Least-privilege token

- `permissions: {}` (or `contents: read`) at the top of every workflow; each job grants what it needs.
- Typical grants: checkout only → `contents: read`; release-plz release → `contents: write` + `id-token: write`; release-plz PR → `contents: write` + `pull-requests: write`; OIDC to AWS → `id-token: write` on that job only; GHCR push → `packages: write`; attestations → `id-token: write` + `attestations: write`; `anthropics/claude-code-action` → `id-token: write` plus what the job does.
- Job-level grants work while the repository default token stays `read`.
- A repo test may pin a job's exact `permissions` dict (setup: `cookbooks/session-search/test/test_workflow_auth.py`). Adding a top-level `permissions: {}` is safe; reshaping the job's dict is not.

## credentials
## Credentials and untrusted input

- `actions/checkout` with `persist-credentials: false`. Keep `true` (with a one-line comment) only where a later step pushes through plain `git push` using the checkout credential: `stefanzweifel/git-auto-commit-action`, signed tags, hand-written `git push`. release-plz, cargo-dist, goreleaser, softprops/action-gh-release and claude-code-action push or release through the API and do not need it.
- Never interpolate `${{ secrets.* }}`, `${{ github.event.* }}`, `${{ inputs.* }}`, `${{ matrix.* }}`, `${{ needs.* }}` or step outputs into `run:`. Pass them through `env:` and use `"$VAR"` — interpolation happens before the shell parses the script, so a crafted branch name or commit message becomes code, and a secret on the command line shows up in process listings.
- No `pull_request_target` or `workflow_run` job that checks out and runs PR code with secrets.
- Release and publish jobs do not restore caches (`actions/cache`, `Swatinem/rust-cache`, `setup-go`/`setup-node` `cache:`): a cache written by a PR build would flow into the published artifact.
- Put the irreversible step last: test → build → attach/attest → publish. `continue-on-error: true` on a publish step hides a broken publish behind a green job; check "already published" explicitly instead.

## timeouts
## Timeouts

`timeout-minutes` on every job (the default is 360). Set it to about 3× the job's normal duration from `gh run list --workflow <file> --json databaseId,createdAt,updatedAt`, and never below the sum of its steps' own `timeout-minutes` — long `workflow_dispatch`-only levels never run on a PR, so a short job timeout passes CI and kills the next manual run.

## generated
## Generated workflows

A workflow written by a generator is fixed at the generator and regenerated, never hand-edited:

- **cargo-dist** (`release.yml` starting with "autogenerated by dist"): `dist plan` runs `dist generate --check` on every PR, so a hand edit, an added comment or a Dependabot bump turns CI red and the next tag release fails at the plan job. Pin its actions through `[workspace.metadata.dist.github-action-commits]` (dist ≥ 0.29), exclude the file from Dependabot (`exclude-paths`), and give it a per-file entry in `.github/zizmor.yml` for what dist hard-codes (root `contents: write`, `${{ matrix.* }}` in `run:`). Verification includes `dist plan` passing on the PR.
- **gh-aw** (`*.lock.yml`): edit the `.md` source and recompile.

## lint
## Lint in CI: zizmor + actionlint

A `supply-chain` job in the repo's CI, triggered on `push` and `pull_request` with no path filter that could exclude `.github/**`, and no `if:` copied from another repo's owner guard:

```yaml
  supply-chain:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@<sha> # vX.Y.Z
        with:
          persist-credentials: false
      - uses: zizmorcore/zizmor-action@<sha> # v0.9.0
        with:
          version: <exact zizmor version>
          advanced-security: false
          online-audits: true
      - uses: docker://rhysd/actionlint@sha256:<digest>
        with:
          args: -color
```

- `online-audits: true` (the default) keeps `impostor-commit` and `ref-version-mismatch`, the audits that catch a wrong SHA or a SHA whose comment lies. They use the job's read-only `GITHUB_TOKEN`.
- Pin `version:` so a new zizmor release cannot turn CI red with no change in the repo; Dependabot does not bump it, so raise it by hand.
- Negative control before relying on the job: push an unpinned `uses:` on a scratch branch and confirm the job fails.
- Run both locally before pushing: `mise x aqua:zizmorcore/zizmor -- zizmor .github/workflows` and `mise x aqua:rhysd/actionlint -- actionlint`.
- Findings go to zero before merge. A justified exception is an inline `# zizmor: ignore[<rule>]` with the reason, or a per-file entry in `.github/zizmor.yml` with a comment (e.g. `superfluous-actions` on a release step kept for now, `use-trusted-publishing` until crates.io trusted publishing is configured).

## loops
## Workflow edits by loops and agents

self-heal, pr-ci-medic, linear-resolve and CoS workers follow this file when they touch a workflow. A PR that changes `.github/workflows` cannot be merged with the gh token (no `workflow` scope): hand it to the owner for a web-UI merge once CI is green. Tag-triggered workflows (release, publish) never run on the PR — after merge, read the first run on `main` and on the next tag before calling the change done.
