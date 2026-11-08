# Herdr 2 (`hc`) route

Load when the owner approves the Herdr 2 (`hc` / `herdr-core`) route for this
session. Everything below was observed on pro-dev on 2026-11-07. Check the
installed `hc --help` and the `herdr-core` skill before relying on any flag.

## Approval and identity

The `hc` route is not a default. The owner approves it in each session; without
that approval use the Herdr 1 route in `dispatch.md`.

Herdr 1 panes and Herdr 2 terminals are separate systems: a pane ID is not a
terminal ID, and neither CLI controls the other's processes. A session running
under `herdr-core hold` has `HC_TERMINAL_ID` set and no `HERDR_*` variables.
Inside that controller terminal, run
`python3 ~/.agents/skills/herdr/caller-context.py resolve` (Codex must run
with `--no-daemon` so its tools retain terminal ancestry). The helper uses
`hc get --json <terminal>` to check that the local terminal is live and both
its root PID and foreground PID are caller ancestors, then rechecks them for
replacement. `HC_TERMINAL_ID` alone is not proof. An active Herdr 1 environment
keeps the existing Herdr 1 verification route.

Require `verified: true` and use the returned `owner` as the ledger's
`--owner`: `hc:<server>#<terminal>`. Here `<server>` is the hc CLI's session
namespace from `HC_SESSION` (trimmed, `default` when empty/unset), not a
session name attested by the core. The installed hc exposes a permanent core
ID and display hostname, but not its session namespace. The helper therefore
rejects hc verification whenever `HC_SOCKET` is set, since it can redirect
that namespace to a different core. Never hand-build the key. If hc is
unavailable, the terminal is absent/finished, process evidence is unavailable, ancestry does not match,
or processes change during verification, hc proof fails. A daemon may have
inherited a stale `HC_TERMINAL_ID`; only when `CODEX_SESSION_ID` is a canonical
UUID does the helper then attempt the independent Herdr 1 Codex resume-session
proof, including its live-process recheck. It never falls back to the Herdr 1
inherited-environment route. A successful resume proof returns Herdr 1
session/socket/pane fields, so use that route's owner key. If both proofs fail,
dispatch is blocked and the error retains the hc reason. Report that error
without selecting another terminal. `prepare`/`verify`
require a canonical UUID `CODEX_SESSION_ID` and implement Herdr 1 Codex visual
proof; they cannot verify hc controllers.

## Launch

The `hc` core starts processes with the PATH
`/usr/local/bin:/usr/bin:/bin:/usr/games`, which lacks `~/.local/bin`, node and
ruby. Project hooks that call bare `ruby` (for example the setup repo's
`ruby .claude/hooks/guard-mitamae-dry-run.rb`) then exit 127 on every Bash call;
hooks that go through `~/.claude/hooks/ruby-shim` still work.

- Start every worker with the controller's PATH so bare-ruby project hooks
  resolve: `/usr/bin/env PATH="$PATH" ...`, expanded in the controller's shell.
- Start Claude by absolute path: `/home/<user>/.local/bin/claude`.
- Start Codex as `/usr/bin/env PATH="$PATH" codex --no-daemon`; the PATH must
  include `~/.local/bin` and node's directory.
- Put the prompt before variadic flags such as `--tools`; a variadic flag
  otherwise consumes the prompt as one of its values.
- Launch without `CLAUDE_CODE_EFFORT_LEVEL` in the environment, as on the
  Herdr 1 route; it overrides the per-worker effort.
- When the attempt's `bin/worker-profile prepare --route hc` plan says
  `launch_ready: true`, launch from it: `/usr/bin/env` with one `-u` per `env_unset` entry,
  one `KEY=VALUE` per `env_set` entry and the controller's PATH, then the plan
  `argv` unchanged, the prompt, and the usual worker-floor and `--tools`
  additions. Otherwise launch as above. See "Worker profiles and launch plans"
  in `dispatch.md`.
- Record the worker terminal with `bind --pane <terminal>` (no `--model` or
  `--effort`: `tasks.py` refuses them for envelope-v1 Herdr attempts) and its effective
  model/effort with `observe --transcript <session-log> --launch-prompt
  <prompt>` (see "Model and effort per attempt" in `dispatch.md`); the session
  logs are the same files as on the Herdr 1 route.
- A prompt passed as argv to a worker in a directory it has not trusted yet
  can sit unsent behind the trust dialog. After the dialog is accepted, read
  the input box and press enter if the prompt is still there.

## Waiting and messages

A worker's `hc send` back to the controller can fail with exit 127 when the
worker was started without the controller's PATH, so a missing message is not
evidence that the worker is still running. The controller keeps one background
`hc wait --children any --timeout 600` (seconds) running so the harness wakes it,
re-checks the terminals and the envelope file on each wake, then re-arms it. A
timeout means "look now", not failure; the ten-minute stall diagnosis in
`SKILL.md` still applies.

The worker notifies with `hc send <controller-terminal> "<one line>"`, never
`--force`, which can answer a dialog. The worker Stop hook works only through
`herdr agent prompt`, so a controller on this route leaves the `COS_*` launch
variables unset and has two signals: the wait and the worker's message.

`hc send` wraps its text in `<hc from=...>` tags, so a slash command such as
`/context` sent with `hc send` reaches the model as an ordinary message. Type
slash commands with `hc keys` instead.

## Cleanup

For a terminal the controller started, run `hc kill <terminal>` and then
`hc rm <terminal>` once its task is `accepted` or `cancelled`. Never kill or
remove a terminal the controller did not start.

## Never run

`hc update`, `hc server stop` and `herdr update`. These change the shared
terminal service itself, which is outside any task's scope.
