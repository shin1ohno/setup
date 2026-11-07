# Git instruction preflight candidate

This is an unapplied SH1-70 review alternative. Existing global rules, deployed
settings, hook deployment lists and generated instructions remain unchanged.
No first-session token saving or model consumption has been measured.

## Candidate

Run `python3 bin/prepare-git-instruction-canary --directory /absolute/new/private/path`.
It partitions the current development source into a complete profile and a
procedural document without rewriting section bodies. Branch checks, merge
approval, verification, signing and attribution policy stay in the profile.
The generated review record identifies removed sections, UTF-8 byte count and
source hash. Bytes are not token measurements.

`hook-candidate.json` is a settings fragment, not a replacement for settings.
For an authorized isolated Claude canary, append its hook to existing hooks and
append the generated profile with global Markdown disabled using the existing
worker-profile preparation workflow. Keep all permission, commit and attribution
hooks. Do not install this fragment globally or run it in the active controller.
Codex receives the explicit read instruction only: this Claude hook is not a
Codex hook and provides no Codex enforcement.

The hook blocks the first recognized mutating Git/GitHub call with exit 2 and
returns the complete procedure as an instruction preflight. It never grants
permission. Subsequent calls continue through existing checks. Session identity
and document hash determine the private marker; a changed document requires a
new preflight. The marker proves response emission, not model reading or
compliance. Command aliases and unknown wrappers can evade recognition, so the
always-loaded read instruction remains necessary. This is not a security boundary.

## Why not context-only or defer

The [public hook reference](https://code.claude.com/docs/en/hooks#pretooluse-decision-control)
specifies that additional context accompanies the tool result. It cannot teach
procedures before the same mutation. `defer` ends a non-interactive turn, ignores
additional context, and is ignored in interactive sessions. It is unsuitable for
this first-call instruction flow. Exit 2 is the explicit, visible alternative;
the response is labeled `GIT_PROCEDURE_PREFLIGHT` rather than permission refusal.

## Review choices

1. Keep existing global rules until the isolated canary passes. There is no new
   preflight interruption and no claimed context reduction.
2. Approve the prepared development-only canary. It introduces one visible
   preflight per session/document revision; existing hard guards stay active.
   It is eligible for rollout only after native transcript evidence confirms
   the first mutation did not run, the procedure arrived, and the retry still
   traversed permission and attribution checks.

In the canary, take exactly one initial `/context` reading in each fresh session,
then inspect the first API usage event with `bin/instruction-usage`. Compare
identical models, plugins, connectors and role. Record the two metrics separately.
Do not derive savings from file size. Debugging/editing/MCP procedure splitting
is outside this first candidate and remains unresolved.
