# Worker instruction profile canary

Status: review proposal for SH1-68/69/72/73/74/78. No launch, account migration,
credential copying or production apply is performed by the preparation helper.

## Artifacts and isolation

`bin/worker-profile render` composes common plus one role from the generated
layer views. `common` is included once. Development, review and operations use
dev; controller uses cos; writing uses writing; other research/admin uses common.
The source remains `cookbooks/claude-code/files/instructions/*.md`.

`check --harness codex --file ABSOLUTE_PROFILE` checks that exact UTF-8 artifact
in **bytes**, including a failing over-32768 case. `worker-profiles.rb` repeats
the cap check on the complete deployed Codex artifact under real mruby. It is
an opt-in recipe (`COOKBOOK=claude-code::worker-profiles`), not part of default
or cloud distribution. Its agent definitions use `omitClaudeMd: true`; actual
Agent-tool omission parity remains a canary criterion.

`prepare` requires a new private directory, actual cwd, explicit model, effort
and reason. It writes a profile, an argv-based launch plan and a short manifest.
It never executes the plan. The output records requested values with observed
values null and launch_ready false. A supplied Codex bundled catalog validates
model/effort support, not account availability or actual execution.

Claude plans retain the built-in system prompt by using the observed
`--append-system-prompt` flag, with `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1`. They unset
`CLAUDE_CODE_EFFORT_LEVEL` for the invocation. They do not change
`CLAUDE_CONFIG_DIR`, global settings or permission flags. An empty appended prompt
does not disable global instructions. `--system-prompt` is not used.

Codex plans use a fresh CODEX_HOME, profile AGENTS.md and
`project_doc_max_bytes=0`, with the observed `--no-daemon` CLI option. No auth.json
link or copy is made; ambient API-key variables are excluded from the proposed
invocation. This home is intentionally **not authenticated**. The existing
operator auth store is neither read for secrets nor changed.

Official references:

- [Global instruction discovery](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
- [Configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Credential storage](https://learn.chatgpt.com/docs/auth)

Codex 0.166.0 `debug prompt-input` verifies the effective instruction input without
starting a model turn: a private global sentinel survives while the project
sentinel disappears with max_bytes=0. The regression also tests the complete
rendered development profile. This does not demonstrate login or API token usage.
The conservative 32 KiB artifact guard stays even where global discovery is not
bounded by the project-doc limit.

## Authentication and rollout decision

Two viable review paths preserve the original isolation acceptance:

1. Authorize a dedicated login in the isolated home, then canary its context and
   startup usage. This avoids credential sharing but requires explicit account
   setup and has per-home lifecycle overhead. This branch does not perform it.
2. Keep existing launches unchanged while verifying a supported shared credential
   mechanism for separate homes. File/keyring behavior must be observed on the
   target host before any sharing implementation. This does not meet isolated
   worker acceptance yet; it avoids deploying an unproven auth wrapper.

Sharing the current CODEX_HOME or symlinking its auth file is not presented as
equivalent isolation. Do not weaken the byte guard to make a profile pass.
Direct sessions with no explicit profile remain unchanged. Cwd-based automatic
routing is unimplemented pending an owner-approved directory map; never classify
unmatched directories as development silently.

## Startup-floor and usage measurements

Preparation leaves the tool/plugin/connector floor unchanged.

Fresh-session `/context` and required-tool spot checks must decide whether each
`~/.claude/worker-floor/*.json` setting removes definitions or only disables use.
Claude quota/access has not been retested here; no model session was launched.

`bin/instruction-usage` consumes supplied JSONL. For Claude it adds first reported API
input, cache creation and cache read once; for Codex it does not double-count
cached input already included in input_tokens. Codex `turn.completed` reports a turn aggregate, which may include several model
calls; it is not proof of first-API-call input. The helper stops at the first
reported usage event, so duplicate blocks and later output do not inflate it.
Retain a separate first-call runtime trace before comparing initial API costs. Byte lengths and prompt JSON lengths are not token measurements.

Record one fresh reading per profile, host, CLI version, applied commit and
connector state. Preserve source transcript references outside the repository.
SH1-68's November 4 measurements remain historical evidence; new local token
totals, before/after floor tables, owner reduction targets and numerical
delegation thresholds are unmeasured/unset. Do not replace them with estimates.

Exit criteria before rollout: isolated Claude/Agent and Codex effective context,
login, requested model/effort observed in startup/session evidence, first-call
usage, required integrations, local cookbook dry-run, and a canary host check.
No issue is complete merely because source generation or fake fixtures pass.
