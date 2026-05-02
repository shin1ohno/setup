# Neovim Configuration Guidelines

This file covers the `~/.config/nvim` repo (AstroNvim-based) and any other shared-dotfile Neovim setup. The patterns here came from concrete cycles burned, not theoretical risks.

## `:Lazy sync` does not switch the recorded branch

When a plugin's spec changes from `branch = "master"` to `branch = "main"` (or any other rename), `:Lazy sync` alone often does NOT switch the on-disk plugin to the new branch — `lazy-lock.json` retains the old `branch:` entry and Lazy honors the lockfile.

Triggers this hits hardest:

- nvim-treesitter master → main migration (master is archived as of 2026-04, but the lockfile keeps `"branch": "master"` until forced)
- Any plugin that rewrites APIs on a new default branch and announces backward-compat freeze on the old one

**Resolution sequence** (cheapest first):

1. `:Lazy update <plugin>` — explicitly target the plugin; this re-reads the spec
2. If the lockfile branch entry is still wrong after step 1, edit `lazy-lock.json` to remove the entry, then `:Lazy restore` / `:Lazy sync`
3. If the on-disk plugin dir was checked out on the old branch and has stale build artifacts (parser .so files, native modules), nuke the plugin dir AND any auxiliary cache:

   ```bash
   rm -rf ~/.local/share/nvim/lazy/<plugin> \
          ~/.local/share/nvim/site/parser  # nvim-treesitter only
   ```

   then restart nvim and let Lazy reinstall fresh from the spec.

**Verify the switch took effect**:

```vim
:lua print(vim.fn.system({"git","-C",vim.fn.stdpath("data").."/lazy/<plugin>","branch","--show-current"}))
```

The output is the source of truth — not the lazy-lock.json field, not the plugin spec.

## Mason PATH is not injected for headless nvim subprocesses

`mason.nvim` adds `~/.local/share/nvim/mason/bin` to `vim.env.PATH` only after Mason loads in an interactive session. Headless invocations (`nvim --headless +<cmd>`) get the user's login PATH only — any subprocess that resolves Mason-installed binaries via PATH will fail with `ENOENT (cmd): '<binary>'`.

The most common case: `nvim --headless +"TSInstall! lua"` fails silently with `Error during "tree-sitter build": ... ENOENT (cmd): 'tree-sitter'` even though `:MasonInstall tree-sitter-cli` already placed the binary on disk.

**Fix for verification scripts**:

```bash
PATH="$HOME/.local/share/nvim/mason/bin:$PATH" nvim --headless +"TSInstall! markdown" +qa
```

This is purely for headless verification — interactive sessions are unaffected because Mason's autoload runs there.

## Headless error observation idiom

Use this exact pattern when a plugin fails on file open and you need to see the actual error without the user reproducing:

```bash
nvim --headless \
  +"edit /tmp/repro.<ext>" \
  +"sleep 3" \
  +"messages" \
  +qa 2>&1 | grep -iE "error|attempt to|nil value|invalid|E[0-9]+:"
```

The `sleep 3` is not optional — many BufReadPost autocommands (treesitter highlighter, render-markdown, aerial) run via `vim.schedule_wrap` and fire after the synchronous edit returns. Without the sleep, `:messages` runs before the error has been recorded.

For a parser/treesitter-related crash specifically, follow up with the source-trace-first protocol from `~/.claude/rules/debugging.md` — read `<plugin>/lua/.../<file>:<line>` from the stack trace before launching a research agent.

## Cross-machine state divergence — every nvim fix needs a cleanup note

The user's `~/.config/nvim` is shared across machines (Linux + Mac) via git. The git-tracked config lives in the repo, but plugin state lives outside it:

- `~/.local/share/nvim/lazy/` — installed plugins, branches, build artifacts
- `~/.local/share/nvim/site/parser/` — compiled treesitter parsers
- `~/.local/share/nvim/mason/` — Mason-installed tools

When a fix involves any of those directories on machine A, machine B does NOT pick up the fix from `git pull` alone — it has stale plugin state that may still hit the original failure.

**Required actions when committing a Neovim fix that touches off-repo state**:

1. Either confirm in the same session that all sharing machines are also fixed, OR
2. Write a TODO.md entry (`<repo>/TODO.md` or `~/.claude/projects/<slug>/memory/TODO.md`) with the exact cleanup commands for the other machine, OR
3. Embed the cleanup commands in the commit message body so the other machine's user sees them on `git log`

The cleanup command for nvim-treesitter / parser cache class fixes is:

```bash
rm -rf ~/.local/share/nvim/lazy/nvim-treesitter \
       ~/.local/share/nvim/lazy/nvim-treesitter-textobjects \
       ~/.local/share/nvim/site/parser
```

Do not declare the fix complete until either (a) all sharing machines are confirmed fixed, or (b) the deferral is explicit and actionable.

This rule exists because the 2026-05-01 nvim-treesitter migration session fixed Linux, the user pulled on Mac, and Mac surfaced the same error because the `:Lazy update` branch-switch didn't take. The Mac required the nuke command above. One round-trip lost; preventable with a commit-message cleanup note at fix time.
