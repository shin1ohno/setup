# Worker instruction profile canary

Status: SH1-68/69/72/73/74/78. The pro-dev canary of 2026-11-08 passed for Claude on
Herdr 2 (`hc`), Claude on the Agent tool and Codex on `hc`; `bin/worker-profile prepare
--route <route>` reports `launch_ready: true` for exactly those pairs. The preparation
helper never launches, migrates accounts, copies credentials or applies cookbooks.

## Artifacts and isolation

`bin/worker-profile render` composes common plus one role from the generated
layer views. `common` is included once. Development, review and operations use
dev; controller uses cos; writing uses writing; other research/admin uses common.
The source remains `cookbooks/claude-code/files/instructions/*.md`.

`check --harness codex --file ABSOLUTE_PROFILE` checks that exact UTF-8 artifact
in **bytes**, including a failing over-32768 case. `worker-profiles.rb` repeats
the cap check on the complete deployed Codex artifact under real mruby. It is
an opt-in recipe (`COOKBOOK=claude-code::worker-profiles`), not part of default
or cloud distribution. Its agent definitions use `omitClaudeMd: true`.

`prepare` requires a new private directory, actual cwd, explicit model, effort
and reason, and refuses when the deployed profile or Codex home is missing or
differs from the rendered source. It writes an argv-based launch plan and never
executes it. Observed model and effort stay null in the plan (the controller
records them with `tasks.py observe`). `launch_ready` is per route: pass
`--route hc|agent|herdr1`; it is true only for a harness/route pair a canary has
observed (`CANARIED` in `bin/worker-profile`), and false with a reason in `note`
otherwise, including when `--route` is omitted. A supplied Codex bundled catalog
validates model/effort support, not account availability or actual execution.

Claude plans retain the built-in system prompt by using the observed
`--append-system-prompt-file` flag, with `CLAUDE_CODE_DISABLE_CLAUDE_MDS=1`. They unset
`CLAUDE_CODE_EFFORT_LEVEL` for the invocation. They do not change
`CLAUDE_CONFIG_DIR`, global settings or permission flags. An empty appended prompt
does not disable global instructions. `--system-prompt` is not used.

Codex plans point `CODEX_HOME` at the fixed per-profile home
`~/.agents/codex-homes/<profile>/` that `worker-profiles.rb` creates (mode 700:
profile `AGENTS.md`, a two-key `config.toml`, and `auth.json` as a symlink to
`~/.codex/auth.json`, the file credential store). They pass `project_doc_max_bytes=0`,
the observed `--no-daemon` option and an inline-table trust override for the cwd,
and unset ambient API-key variables. The helper reads only the home's `AGENTS.md`;
it never opens `auth.json`.

Official references:

- [Global instruction discovery](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
- [Configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Credential storage](https://learn.chatgpt.com/docs/auth)

Codex 0.166.0 `debug prompt-input` verifies the effective instruction input without
starting a model turn: a private global sentinel survives while the project
sentinel disappears with max_bytes=0. The regression also tests the complete
rendered development profile. The conservative 32 KiB artifact guard stays even
where global discovery is not bounded by the project-doc limit.

## Authentication

Owner decision (2026-11-08): Codex workers use the file credential store through
the `auth.json` symlink in each fixed home; keyring is out of scope. SH1-69
(2026-11-07) showed a separate `CODEX_HOME` holding only that symlink stays logged
in, and the canary below repeated it for all four homes. Do not weaken the byte
guard to make a profile pass. Direct sessions the owner opens keep the full
instruction set; profiles apply only to workers the controller launches.

## pro-dev canary, 2026-11-08

Host pro-dev (CT 104), Claude Code 2.1.319, codex-cli 0.167.0, setup `main` at
`cbfaf84` with `claude-code::worker-profiles` applied the same day. Workers ran in a
fresh empty directory under `/tmp` holding decoy `AGENTS.md` and `CLAUDE.md` files;
Claude workers used `claude-sonnet-5-5` at effort `low`, Codex workers `gpt-6.1-sol`
at effort `low`. Each worker got a unique nonce prompt and answered it. Raw output
is kept outside the repository in the chief-of-staff task directory
`2f450fa61ab14018` (`canary.md` there lists every evidence file).

| profile | herdr (`hc`) Claude | Agent tool | Codex (`hc`) |
|---|---:|---:|---:|
| common | 57,766 (system prompt 10.9k) | 26,594 | 23,401 |
| dev | 74,494 (27.6k) | 43,321 | 27,395 |
| cos | 66,623 (19.7k) | 35,446 | 24,993 |
| writing | 58,687 (11.8k) | 27,510 | 23,744 |

All 12 cells passed. Numbers are first-call input tokens: for Claude,
`bin/instruction-usage` on the session log (input + cache creation + cache read);
for Codex, `last_token_usage.input_tokens` of the rollout's first `token_count`
event (one turn). The parenthesised values are the `/context` "System prompt" row.
Totals differ between routes because the base prompt, the tool set and the skill
listing differ (herdr workers listed 197 skills in 28,229 characters, subagents 184
in 14,438), not because of the profile text.

How each cell was judged:

- **Claude, both routes.** The session log records the system prompt as sent
  (`prompt_snapshot` attachment) and the first request's messages
  (`api-request-blob`). The check reads those, not the file passed in, and
  requires the common sentinel and the profile's own sentinel, each unique to its
  layer, while the other roles' sentinels, the `Contents of ~/.claude/CLAUDE.md` and
  rules headers and both decoy tokens are absent and no `instructions` files were
  loaded. On a full-instruction session the same check fails. `/context` showed no
  Memory files row on any herdr worker.
- **Same set on both Claude routes (SH1-72 AC2).** The full deployed
  `~/.agents/profiles/<profile>.claude.md` text is a verbatim substring of both the
  herdr and the Agent-tool system prompt for every profile. Before the Agent call,
  the sha256 of each `profile-<profile>.md` body matched the plan's
  `instruction_sha256` (the dispatch.md gate).
- **Codex.** `codex debug prompt-input` with the plan's `CODEX_HOME`, `env_unset` and
  `-c` flags in the decoy cwd contained the full home `AGENTS.md` and the expected
  sentinels and no decoy; overriding `project_doc_max_bytes=32768` makes the decoy
  appear, so the check can fail. The live rollout's injected messages passed the
  same check, its `turn_context` showed the requested model and effort, every worker
  answered from the model, and `auth.json` stayed a symlink.

Codex side effects: running the TUI adds `[tui] screen_reader_detection_done = true`
and `[tui.model_availability_nux] "gpt-6.1-sol" = 1` to each home's `config.toml`
(accepted by the owner), and leaves runtime state (sessions, sqlite stores, model
cache) in the home. Every Codex worker warns at startup that bubblewrap is not on
PATH and uses its bundled copy; the warning is cosmetic. Two Codex workers started
at the same moment on one home both answered and wrote separate rollouts.

Open issues:

- Herdr 1 launches (`herdr pane split --env`, `pane run unset`, `agent start --kind`)
  were not exercised, so `--route herdr1` stays not launch-ready.
- `dispatch.md` and `hc-route.md` call `prepare` without `--route`, which now yields
  `launch_ready: false`; they need to pass the attempt's route before any worker
  launches from a plan.
- A simultaneous OAuth token refresh by two workers on one `auth.json` was not
  exercised (no refresh happened during the short turns).

## Startup-floor and usage measurements

Preparation leaves the tool/plugin/connector floor unchanged.

Fresh-session `/context` and required-tool spot checks must decide whether each
`~/.claude/worker-floor/*.json` setting removes definitions or only disables use.
The canary above launched without the worker-floor settings and `--tools` additions.

`bin/instruction-usage` consumes supplied JSONL. For Claude it adds first reported API
input, cache creation and cache read once; for Codex it does not double-count
cached input already included in input_tokens. Codex `turn.completed` reports a turn aggregate, which may include several model
calls; it is not proof of first-API-call input. The helper stops at the first
reported usage event, so duplicate blocks and later output do not inflate it.
Retain a separate first-call runtime trace before comparing initial API costs. Byte lengths and prompt JSON lengths are not token measurements.

Record one fresh reading per profile, host, CLI version, applied commit and
connector state. Preserve source transcript references outside the repository.
SH1-68's November 4 measurements remain historical evidence; before/after floor
tables, owner reduction targets and numerical delegation thresholds are
unmeasured/unset. Do not replace them with estimates.

Remaining before default rollout (SH1-72/73 step D): the Herdr 1 route, the
dispatch.md `--route` pass-through, required integrations under the worker-floor
settings, and a local cookbook dry-run of the default recipe.
