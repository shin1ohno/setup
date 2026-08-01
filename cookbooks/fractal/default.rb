# frozen_string_literal: true

# fractal — hierarchical agent loops with recursive self-organization
# (plasma.ai). Autonomous agent loops arrange themselves into a tree of git
# worktrees, bounded by hard caps (iterations, depth, children, cost, time).
# https://www.plasma.ai/research/fractal  •  github.com/plasma-ai/fractal
#
# Not in the mise core registry and the GitHub repo publishes no release
# assets, so pipx: is the only viable mise backend (PyPI: plasma-fractal —
# canonical name; "fractal" is an alias). mise's pipx backend prefers uv
# (via uvx) when uv is spawnable, and only falls back to a literal pipx
# binary otherwise (src/backend/pipx.rs, install_version_ -- confirmed by
# reading mise's pinned-version source, not the mise docs) -- on a bare
# Ubuntu box, NEITHER is present, so `mise use --global pipx:plasma-fractal`
# fails outright ("pipx is required ... but was not found", exit 1),
# aborting the rest of linux.rb (mitamae has no ignore_failure). Bootstrap
# uv first via mise's own aqua-backed core tool so the pipx backend's uv
# path is taken.
#
# plasma-wiki is installed as a second tool because isolated pipx/uv
# installs do NOT expose the `wiki` executable from plasma-fractal's
# dependency (README-documented gotcha — a plain `pip install` would).
# Two separate mise tools put both executables on PATH via shims.
#
# The companion /fractal Claude Code skill (fractal@plasma) is registered
# by the claude-code cookbook via the plasma-ai/plugins marketplace and
# enabled via enabledPlugins.
include_cookbook "mise"

mise_tool "uv"

mise_tool "plasma-fractal" do
  backend "pipx"
end

mise_tool "plasma-wiki" do
  backend "pipx"
end

# zsh completions. Both CLIs are Typer apps; `--show-completion` relies on
# shellingham parent-process detection, which fails in non-TTY mitamae runs
# ("Shell  not supported."). The Click-7-style instruction env that typer
# 0.27 preserves (`source_zsh`) is deterministic and TTY-free. The generated
# script carries a `#compdef` header, so it autoloads from fpath
# (~/.local/share/zsh/site-functions is created by the mise cookbook and put
# on fpath pre-compinit by dot-zsh). Script content is a version-independent
# dynamic-dispatch stub — no regeneration needed on upgrades.
# The typer script registers `compdef` but (unlike Click's own template)
# lacks the loadautofunc branch, so the very first fpath-autoloaded TAB
# would complete nothing — append a direct invocation to cover it.
{ "fractal" => "_FRACTAL_COMPLETE", "wiki" => "_WIKI_COMPLETE" }.each do |cli, var|
  dst = "#{node[:setup][:home]}/.local/share/zsh/site-functions/_#{cli}"
  execute "generate #{cli} zsh completion" do
    user node[:setup][:user]
    # sed '/./,$!d' strips the leading blank line typer emits — compinit
    # only honors a `#compdef` tag on line 1.
    command "#{var}=source_zsh $HOME/.local/share/mise/shims/#{cli} | sed '/./,$!d' > #{dst} && echo '_#{cli}_completion \"$@\"' >> #{dst}"
    not_if "test -s #{dst}"
  end
end
