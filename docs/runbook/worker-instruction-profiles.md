# Worker instruction profile canary

Status: SH1-68/69/72/73/74/78. The pro-dev canary of 2026-11-08 passed for Claude on
Herdr 2 (`hc`), Claude on the Agent tool and Codex on `hc`. The 2026-11-09 canary
also passed for Claude and Codex on Herdr 1. `bin/worker-profile prepare
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
profile `AGENTS.md`, a `config.toml`, and `auth.json` as a symlink to
`~/.codex/auth.json`, the file credential store). They pass `project_doc_max_bytes=0`,
the observed `--no-daemon` option and an inline-table trust override for the cwd,
and unset ambient API-key variables. The helper reads only the home's `AGENTS.md`;
it never opens `auth.json`. The profile config includes `approval_policy` and
`sandbox_mode` from `generate_config.sh --permission-policy`, the same defaults
and user preamble used by the main Codex config generator. This avoids reading
a stale main config when claude-code converges before codex-cli. The mode emits
only those two root keys; provider credentials and MCP settings are not copied.

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

Log in with the normal `codex` (default `CODEX_HOME`), never from a profile
home. On a host where Codex has never logged in, each home's `auth.json` is a
dangling link and Codex reports "Not logged in"; `codex login` run from a
profile home writes through the link to `~/.codex/auth.json` and fails with
ENOENT when `~/.codex` does not exist (owner decision 2026-11-08: accepted).

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

- Herdr 1 was not exercised in this November 8 run; its separate November 9
  canary is recorded below.
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

Remaining before default rollout (SH1-72/73 step D): required integrations under
the worker-floor settings and a local cookbook dry-run of the default recipe.

## Herdr 1 canary, 2026-11-09

The pro-dev canary used sibling panes created with `pane split --env`, sent
the plan's `env_unset` through `pane run unset`, then passed `argv[1:]` to
`agent start --kind`. Both harnesses answered unique nonce prompts. Their
session logs contain the complete deployed dev profile. `tasks.py observe`
recorded `claude-haiku-5-5` / `low` and `gpt-6-luna` / `low` respectively.
`herdr1` was added to `CANARIED` only after these observations.

Claude's with-profile session was `7dd923b9-ec1b-42f7-97d6-d9d2469f9468`;
the without-profile baseline was `ffcfe147-b945-4523-a793-274517664a05`.
Both used `haiku`, effort `low`, the same worktree
`~/ManagedProjects/setup/.claude/worktrees/cos-profile-routes`, the same nonce
prompt, `--settings ~/.claude/worker-floor/impl.json`, and
`--tools Bash,Read,Edit,Write,Skill,ToolSearch,Agent,AskUserQuestion`.
The baseline omitted only `--append-system-prompt-file` and
`CLAUDE_CODE_DISABLE_CLAUDE_MDS`; both sent `unset CLAUDE_CODE_EFFORT_LEVEL`.
Separate `--session-id` values identified the two logs. The targeted ambient
variables were not set in the inspected environment; sending `unset` and its
exit status do not demonstrate removal of a populated variable. This canary
does not prove that environment-clearing behavior.

| Claude launch | First-call input tokens |
|---|---:|
| Without profile | 79,748 |
| With dev profile | 54,168 |
| Reduction | 25,580 |

Counts include input, cache creation and cache read from the first assistant
API usage. The same-condition reduction exceeds the owner's 15,000-token
acceptance threshold. These observations do not establish an absolute 50k
ceiling or a comparison to the November 8 launches without floor/tools.

Evidence is retained under chief-of-staff task `4e44aceb101e4527` in
`~/.local/state/chief-of-staff/`: `evidence/comparison.json`,
`evidence/profile-claude-first-call.json`, `evidence/claude-first-call.json`,
`evidence/profile-claude-observe.txt`, and `evidence/codex-observe.txt`.
The original with-profile evidence was copied from task `3c32d0d312284686`.

The ledger now records `hc`, `herdr1`, or `agent` and the used plan file in
`attempt --plan`. A default launch omits the plan. Legacy `herdr` (or a missing
route) stays an unspecified terminal route; it supports `bind --pane` and
`observe` without guessing whether the launch used Herdr 1 or Herdr 2. Reuse
inherits the original plan, while a different supplied plan is refused. New
plan arguments must be existing absolute JSON files with the same route.

### Tool-using Codex canary

The initial nonce canary made no tool calls and did not verify permissions.
The follow-up session `01a1bbf1-73fc-7693-bfb0-ba0a22cf9ca9` used the real
recipe's generated config in a task-local Codex home (with the existing auth
file linked, not copied). Its `turn_context` recorded `approval_policy: never`
and `sandbox_policy.type: danger-full-access`, matching the user's policy.
The worker executed a probe script that wrote a task-local file, committed in
a throwaway repository and its linked worktree, called read-only `gh api user`,
and ran `herdr --session default agent list`. All five probes succeeded; the
controller re-read the output file and both commit IDs. The pane was closed.

Task `4e44aceb101e4527` retains `evidence-2/canary-turn-context.json`,
`evidence-2/canary-verification.json`, and one `tool-*.json` result per probe.
The permission-mode change leaves normal generator output byte-identical in
five fixtures (defaults, either override, both overrides, and nested profile
keys), recorded in `evidence-2/generator-comparison.json` with before/after TOML.
