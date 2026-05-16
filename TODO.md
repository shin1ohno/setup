# TODO

## Fix rbenv profile shims PATH

- File: `cookbooks/rbenv/commands.rb:16`
- Profile exports `~/.setup_shin1ohno/rbenv/shims` which does not exist; real
  shims live at `~/.rbenv/shims` (= `node[:rbenv][:root]/shims`). Currently
  fine for interactive shells because the lazy `rbenv()` function evals
  `rbenv init`, which corrects PATH. Broken for non-interactive contexts
  (Claude Code hooks, cron, systemd timers running mitamae sub-shells).
- Claude hooks worked around it via a `ruby-shim` in the claude-code
  cookbook (PR fix/claude-hooks-ruby-and-gpg-snapshot). The bogus PATH
  entry remains for all shells until this is fixed at the source.
- First step: change `commands.rb:16` to use `#{node[:rbenv][:root]}/shims`
  instead of `#{node[:setup][:root]}/rbenv/shims`. Verify on both linux
  (`node[:rbenv][:root]` defaults via `roles/programming/default.rb:11-13`)
  and darwin. Drop the claude-code `ruby-shim` once the upstream fix lands
  and is deployed everywhere.
