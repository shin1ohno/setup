# GitHub Actions — Supply-Chain Baseline

Load when creating, editing or reviewing a workflow under `.github/workflows/`, or when a loop (self-heal, pr-ci-medic, a CoS worker) is about to change one. Adapted from sorah/config `sorah-guides/skills/github-ci`.

## pinning
## Pin every remote action by commit SHA

```yaml
- uses: actions/checkout@<40-hex commit SHA> # v5.0.0
```

- Full 40-hex **commit** SHA, then one space, `#`, one space and the full semver tag. Local `./` actions and reusable workflows in the same repo are exempt. House style: `ai-memory/.github/workflows/ci.yml`, `session-search/.github/workflows/ci.yml`.
- Pin with pinact: `mise x aqua:suzuki-shunsuke/pinact -- pinact run` (uses `GITHUB_TOKEN`; `pinact run -u` updates to the latest tag). By hand: `gh api repos/<owner>/<repo>/commits/<tag> --jq .sha` — the commits endpoint dereferences annotated tags; `git/ref/tags/<tag>` returns the tag object SHA for an annotated tag, which is wrong.
- A ref that carries meaning (`dtolnay/rust-toolchain@stable`, `@nightly`, `@1.85`) selects the toolchain by its name. Pin the SHA and pass the toolchain explicitly: `with: { toolchain: stable }`.
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

Dependabot rewrites both the SHA and the trailing version comment. One grouped PR per repo per month; it touches `.github/workflows`, so it merges through the web UI (the gh token has no `workflow` scope). Dependabot PRs get no repository secrets: a CI job that needs a secret must be skipped for `github.actor == 'dependabot[bot]'` or the PR stays red.

## permissions
## Least-privilege token

- `permissions: {}` (or `contents: read`) at the top of every workflow; each job grants what it needs.
- Typical grants: checkout only → `contents: read`; release-plz release → `contents: write` + `id-token: write`; release-plz PR → `contents: write` + `pull-requests: write`; OIDC to AWS → `id-token: write` on that job only; GHCR push → `packages: write`; attestations → `id-token: write` + `attestations: write`.
- Job-level grants work while the repository default token stays `read`.

## credentials
## Credentials and untrusted input

- `actions/checkout` with `persist-credentials: false`. Exception: a job that later pushes with the checkout token (release-plz, git-auto-commit) keeps it and says why in a one-line comment.
- Never interpolate `${{ secrets.* }}`, `${{ github.event.* }}`, `${{ inputs.* }}`, `${{ matrix.* }}` or step outputs into `run:`. Pass them through `env:` and use `"$VAR"` — interpolation happens before the shell parses the script, so a crafted branch name or commit message becomes code, and a secret on the command line shows up in process listings.
- No `pull_request_target` or `workflow_run` job that checks out and runs PR code with secrets.
- Release jobs do not restore caches (`actions/cache`, `Swatinem/rust-cache`, `setup-*` `cache:`): a cache written by a PR build would flow into the published artifact.
- Put the irreversible step last: test → build → attach/attest → publish.

## timeouts
## Timeouts

`timeout-minutes` on every job (the default is 360). Set it to roughly 3× the job's normal duration.

## lint
## Lint in CI: zizmor + actionlint

A `supply-chain` job in the repo's CI (or its own workflow on `push` / `pull_request` for `.github/**`):

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
      - uses: zizmorcore/zizmor-action@<sha> # vX.Y.Z
        with:
          advanced-security: false
      - uses: docker://rhysd/actionlint@sha256:<digest>
        with:
          args: -color
```

- Run both locally before pushing: `mise x aqua:zizmorcore/zizmor -- zizmor .github/workflows` and `mise x aqua:rhysd/actionlint -- actionlint`.
- Findings go to zero before merge. A justified exception is an inline `# zizmor: ignore[<rule>]` with the reason on the same line.
- A generated workflow (cargo-dist `release.yml`, gh-aw `*.lock.yml`) is fixed at its generator's config and regenerated, never hand-edited.

## loops
## Workflow edits by loops and agents

self-heal, pr-ci-medic, linear-resolve and CoS workers follow this file when they touch a workflow. A PR that changes `.github/workflows` cannot be merged with the gh token (no `workflow` scope): hand it to the owner for a web-UI merge once CI is green.
