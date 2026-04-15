---
description: "Git commit message format rules — loaded when creating commits"
---

# Git Commit Format

## First Line (Summary)

- Start with `{component}: ` prefix when possible (shortened filename or directory)
- Prefer contextful verbs over generic "Change", "Add", "Fix", "Update"
- Explain the "why", not just the "what"

## GPG Signing Failures

If `git commit` fails with a GPG signing error or timeout, present the user with `! gpg-connect-agent reloadagent /bye` to reload the GPG agent and cache the passphrase. Do not bypass signing with `-c commit.gpgsign=false` unless the user explicitly requests it.
