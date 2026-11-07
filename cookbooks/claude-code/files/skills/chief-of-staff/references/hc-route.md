# Herdr 2 (`hc`) route

Load when the owner approves the Herdr 2 (`hc` / `herdr-core`) route for this
session. Everything below was observed on pro-dev on 2026-11-07. Check the
installed `hc --help` and the `herdr-core` skill before relying on any flag.

## Approval and identity

The `hc` route is not a default. The owner approves it in each session; without
that approval use the Herdr 1 route in `dispatch.md`.

Herdr 1 panes and Herdr 2 terminals are separate systems: a pane ID is not a
terminal ID, and neither CLI controls the other's processes. A session running
under `herdr-core hold` has `HC_TERMINAL_ID` set and no `HERDR_*` variables, so
the Herdr 1 caller helper cannot verify it. Record the controller terminal as
the ledger owner in the form `hc:<server>#<terminal>`; the string used on
2026-11-07 was `hc:default#t1`.

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
- A prompt passed as argv to a worker in a directory it has not trusted yet
  can sit unsent behind the trust dialog. After the dialog is accepted, read
  the input box and press enter if the prompt is still there.

## Waiting and messages

A worker's `hc send` back to the controller can fail with exit 127, so a
missing message is not evidence that the worker is still running. The
controller waits with `hc wait --children` and then reads the envelope file.

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
