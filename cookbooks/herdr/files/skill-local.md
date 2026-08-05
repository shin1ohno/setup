## Local integration (mitamae-managed)

This machine's herdr is managed by `cookbooks/herdr` in the setup repo
(`~/ManagedProjects/setup`). Three consequences for work you do from a pane.

**`~/.config/herdr/config.toml` is a render target, not a source.** The
cookbook rewrites it on every apply, so a direct edit disappears at the next
converge. To change a keybinding or the theme, edit
`cookbooks/herdr/files/config.toml`, apply, then run
`herdr server reload-config` to load it into the running server.

**Do not run `herdr update` or `herdr channel set`.** The cookbook pins the
release by version plus sha256 and reinstalls the pinned binary whenever the
on-disk one reports a different version, so a self-update is reverted at the
next apply — and until then the session runs a version the pin does not
describe. To move versions, bump `herdr_version` and the checksums in
`cookbooks/herdr/default.rb`. The agent skill and the zsh completion are
generated from that pinned binary, so they follow the bump automatically.

**`hr` is the local session entry point** — a shell function from the same
cookbook. `hr <name>` creates or attaches that named session; bare `hr`
fzf-picks an existing session and falls back to the default one.

Keybindings that differ from herdr's defaults (the full set is in the
cookbook's `config.toml`): prefix is `ctrl+a`, splits are `prefix+|`
(side-by-side) and `prefix+\` (stacked), copy mode is `prefix+v`, and pane
focus is a prefix-less `ctrl+h` / `ctrl+j` / `ctrl+k` / `ctrl+l`. Inside
neovim those focus keys are intercepted by smart-splits.nvim, which does not
recognize herdr as a multiplexer target, so a vim split does not hand off to
the next herdr pane. Do not instruct the user to cross that boundary with
`ctrl+hjkl`.
