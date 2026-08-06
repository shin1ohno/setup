## Local integration (mitamae-managed)

This machine's herdr is managed by `cookbooks/herdr` in the setup repo
(`~/ManagedProjects/setup`).

**`~/.config/herdr/config.toml` is a render target, not a source.** The
cookbook rewrites it on every apply, so a direct edit disappears at the next
converge. To change a keybinding or the theme, edit
`cookbooks/herdr/files/config.toml`, apply, then run
`herdr server reload-config`. Reload live-applies keys, UI, notifications,
update checks and the CJK options; shell/cwd policy affects only new panes,
and a restart is not a substitute — it kills every pane process.

**Do not run `herdr update` or `herdr channel set`, and refuse a `--remote`
binary replacement.** The cookbook pins the release by version plus sha256 and
reinstalls the pinned binary whenever the on-disk one differs, so a self-update
is reverted at the next apply. `channel set` installs immediately on a direct
install, and `--remote` offers to overwrite `~/.local/bin/herdr` when the two
ends disagree. To move versions, bump `herdr_version` and the checksums in
`cookbooks/herdr/default.rb`; this skill and the zsh completion regenerate from
the pinned binary automatically.

**`hr` only works from a shell OUTSIDE herdr.** It is a shell function from the
same cookbook: `hr <name>` creates or attaches that named session, bare `hr`
fzf-picks one. Nested launch is refused (`experimental.allow_nested = false`),
so from inside a pane the user must detach first (`prefix+q`). Its
`… && attach || herdr` chain also falls back to the default session on fzf
cancel, list failure and attach failure alike, so do not read "it opened
default" as "the named session does not exist".

Keybindings that differ from herdr's defaults (full set in the cookbook's
`config.toml`): prefix is `ctrl+a`, splits are `prefix+|` (side-by-side) and
`prefix+\` (stacked), copy mode is `prefix+v`, and pane focus is a prefix-less
`ctrl+h` / `ctrl+j` / `ctrl+k` / `ctrl+l`.

Those four direct focus keys are currently swallowed by herdr before any pane
sees them. Inside neovim that means `ctrl+hjkl` moves herdr panes instead of
neovim splits, and in every pane it means the shell never receives `ctrl+l`
(clear) or `ctrl+h` (backspace). Tell a neovim user to use `ctrl+w h/j/k/l`
for splits until the config is fixed. The fix is upstream-documented:
`herdr plugin link` the installed smart-splits.nvim checkout and rebind the
four keys to its `plugin_action`s, which route by `pane process-info`.

## Corrections and additions to the instructions above

Measured against herdr 0.8.0 on this machine, 2026-08-05. Where this section
disagrees with the text above it, this section was verified more recently.

**Discovery is incomplete in `herdr --help`.** Two whole groups are omitted:
`terminal` (`session observe` is a read-only live ANSI stream; `session
control` is writable and single-owner) and `plugin` (installs and runs
unsandboxed third-party code — never install one implicitly). `herdr server
--help` adds `agent-manifests`, `update-agent-manifests` and
`reload-agent-manifests`, and `pane read` accepts `--source detection` though
the group summary omits it. Run the nested `--help` when precision matters.

**`agent explain <target>` is the diagnosis path and is absent from the
instructions above.** It reports the active manifest, the matched rule and the
evidence string behind a state. Use it before acting on `unknown`, an
unexpected `idle`, or a `blocked` you did not cause.

**A pinned binary does not pin state classification.** Detection rules are
downloaded per agent into `~/.local/state/herdr/agent-detection/remote/*.toml`
with dated versions and hot-reloaded, so the same binary can classify the same
screen differently after an upstream rule change. `agent explain` names the
file and version actually in use.

**`agent read` silently caps at 1000 lines.** Asking for 1500 or 5000 returns
the same 1000 lines with no truncation marker in the CLI output. On an idle
agent a larger `--lines` does recover far more than `visible` (measured: 4 KB
visible vs 65 KB at the cap), so raise it first — but past the cap, ask the
agent to write its full answer to a Markdown file and read the file.

**A prompt submitted immediately after `agent start` can be swallowed.**
`interactive_ready: true` is not proof the TUI accepts input: three of three
fresh Codex agents dropped their first prompt while MCP servers were still
initialising, and the CLI reported success anyway. Pass `--wait` so an
ineffective submission surfaces as `agent_prompt_stalled`, or confirm your own
text is echoed with `agent read` before assuming delivery.

**`agent_prompt_stalled` is ambiguous delivery, not permission to resend.**
The text was already submitted; only the lifecycle change is missing. Inspect
`agent get` and `agent read` first. Prompting an already-`working` agent is
also not turn-correlated — the current turn finishing can satisfy your wait.

**Pass the topology target explicitly.** `tab create` and `workspace create`
without `--workspace` follow the UI-focused workspace, which belongs to the
human and can change mid-task; a fan-out that omitted it put two tabs in the
operator's other workspace. Use `--workspace "$HERDR_WORKSPACE_ID"`, `--cwd`
and `--no-focus` on every creation.

**Detach preserves processes; stopping does not.** `server stop` and `session
stop` kill every pane process. A restart restores layout, cwd and focus only:
pane text returns solely with experimental `pane_history`, and an agent
conversation only when an official integration reported a native session
reference. Never tell the user a restart preserves shells, tests or servers.

**A popup binding (`[[keys.command]]` with `type = "popup"`) is not a pane.**
It is session-modal, disables agent detection and gets no `HERDR_PANE_ID` —
never start an agent in one. Inside a popup, address the underlying pane with
`HERDR_ACTIVE_PANE_ID` and call the CLI through `HERDR_BIN_PATH`.

**`notification show` is best-effort attention with no acknowledgement.**
Check the returned `{shown, reason}`: delivery can come back `disabled`,
`rate_limited`, `no_foreground_client` or `busy`, and nothing is queued while
the human is detached.

**Do not create a herdr worktree when Claude Code already owns one.** Pick one
lifecycle owner: `herdr worktree create` makes a checkout plus a grouped
workspace, `worktree remove` deletes the checkout but never the branch, and
Claude Code's `--worktree` creates its own. For visibility only, `worktree
open --path` the existing checkout.

**There is no `synchronize-panes`.** No key, action, CLI or API method
provides it. Fan out to an explicit, inspected list of pane IDs with `pane
run` / `pane send-text`; do not promise the user a synchronised-input mode.

**Prefer `agent wait` and `pane wait-output` over polling.** The socket API
also has `events.wait` and `events.subscribe` with no CLI wrapper — reach for a
raw protocol client only when you genuinely need an event stream.

**The IME switch follows the client, not the server.**
`switch_ascii_input_source_in_prefix` switches "the host input source" per
upstream and is a no-op outside macOS/Windows, so the machine that performs it
is wherever the foreground herdr client runs. Under `ssh sh1-cloud; herdr` the
client is on Linux and nothing happens; with `herdr --remote sh1-cloud` from
the Mac the client is macOS and it can apply. Which config the remote client
reads for this key is unverified — remote *keybindings* are snapshotted from
the local side by default and `[experimental]` ownership is not documented.
