---
name: security-review
description: Complete a security review of the pending changes on the current branch
user-invocable: true
allowed-tools: ["Bash", "Agent", "Read", "Grep", "Glob", "AskUserQuestion"]
argument-hint: "[base_commit]"
---

# Security Review Skill

## Purpose

Review code changes for security vulnerabilities by diffing against a base commit and delegating the review to a code-review sub-agent if sub-agents are available (otherwise reviewing the diff in this session; Claude Code: the `code-reviewer` agent from `pr-review-toolkit`) with a security-focused prompt.

## Argument Parsing

The invocation arguments (the user's request text; Claude Code: `$ARGUMENTS`) are an optional base commit hash or ref. Examples (written as Claude Code slash commands; in other environments pass the same text as the request):
- `/security-review` — auto-detect base
- `/security-review faee240` — diff from specific commit
- `/security-review main` — diff from branch
- `/security-review 今のコード全てを監査` — natural language; extract hash if present, otherwise auto-detect

## Workflow

### Step 1: Determine Base Commit

Try these in order until one succeeds:

1. **Argument provided**: if the arguments look like a commit hash (hex string) or branch name, use it directly as base
2. **merge-base**: run `git merge-base HEAD origin/$(git rev-parse --abbrev-ref HEAD 2>/dev/null) 2>/dev/null`
3. **Fallback**: show `git log --oneline -15` and ask the user which commit to diff from (use the question tool if available, otherwise write numbered options in the message body; Claude Code: AskUserQuestion / Codex: request_user_input)

### Step 2: Generate Diff

Run: `git diff <base>..HEAD -- . ':!*.bin' ':!*.sqlite3' ':!*.pickle' ':!*.png' ':!*.jpg'`

Also run `git diff <base>..HEAD --stat` for the summary.

If the diff is empty, inform the user and stop.

### Step 3: Launch Security-Focused Code Review

Delegate to a code-review sub-agent if sub-agents are available (otherwise perform the review in this session; Claude Code: launch the `code-reviewer` agent from the `pr-review-toolkit` plugin) with an explicit security-focus prompt. Include:

- The full diff output (excluding binary files)
- The diff stat summary
- A security-focused review directive: "Focus on OWASP Top 10 vulnerabilities (injection, XSS, SSRF, auth/session flaws, crypto misuse, path traversal, unsafe deserialization, etc.) plus secret leakage, unsafe exec/eval, and untrusted input flowing to privileged sinks. Rate each finding by severity (Critical/High/Medium/Low/Info)."
- The domain checklist below, for every item that the diff touches
- Any spec, plan or ADR the change implements (path), with: "Vulnerabilities can come from deviating from the spec and from flaws in the spec itself; report both."
- Instructions to read every touched file in full and follow the call chain, not only the changed lines, and to list the areas examined that appeared secure

Domain checklist (include in the prompt):

- **OAuth 2.0**: redirect URI exact match (no prefix/partial match, no open redirect), authorization code single use, PKCE required and verified (`S256`), refresh token rotation with reuse detection, scope checked per resource, tokens kept out of logs, URLs and Referer.
- **OIDC / JWT**: signature verified against the issuer's JWKS, `exp`/`nbf`, `iss` and `aud` exact match, `nonce` bound to the session, `at_hash`/`c_hash` when the flow returns them, no issuer confusion across multiple providers, `alg` pinned (no `none`, no HS/RS confusion).
- **Sessions and cookies**: fixation, idle and absolute expiry, `Secure` / `HttpOnly` / `SameSite`.
- **Timing**: every comparison of a secret (token, HMAC digest, API key, password hash) is constant-time — Python `hmac.compare_digest`, Rust `subtle::ConstantTimeEq`, Node `crypto.timingSafeEqual`, Ruby `ActiveSupport::SecurityUtils.secure_compare`; no observable difference between an unknown user and a wrong credential (lookup short-circuits before verification).
- **Races**: check-then-use (TOCTOU) on files, symlinks, quotas, one-time codes and token issuance; missing locking on shared state.
- **CI workflows** (`.github/workflows/`): third-party actions pinned by SHA, `permissions:` minimal, `${{ }}` from events/inputs not interpolated into `run:`, secrets not exposed to `pull_request_target` / fork PRs (`~/.claude/docs/github-actions.md`).

The Claude Code `code-reviewer` agent already supports confidence scoring (0-100) per finding; use its output format directly (without it, attach a 0-100 confidence score to each finding yourself).

### Step 4: Present Results

When the review completes, present findings organized by severity (Critical → High → Medium → Low → Info). Include:

- Total finding count by severity
- Each finding with file:line, attack vector, and remediation
- "No findings" sections explicitly listed
