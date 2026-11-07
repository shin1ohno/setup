#!/bin/sh
# Run a project hook script with ruby even when ruby is not on PATH
# (hc workers on pro-dev start with PATH=/usr/local/bin:/usr/bin:/bin).
# Usage: run-ruby.sh <hook-script-name.rb>   (resolved next to this file)
# Self-contained: no dependency on ~/.claude/hooks/ruby-shim.
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
script="$dir/$1"
shift
PATH="$HOME/.rbenv/shims:$HOME/.local/share/mise/shims:$HOME/.local/bin:/opt/homebrew/bin:$PATH"
export PATH
if ! command -v ruby >/dev/null 2>&1; then
  # mise shim dir may be absent; fall back to the newest installed mise ruby
  for r in "$HOME"/.local/share/mise/installs/ruby/*/bin/ruby; do
    [ -x "$r" ] && PATH="$(dirname "$r"):$PATH"
  done
  export PATH
fi
# -E UTF-8: hooks may start without a UTF-8 locale; JSON.parse of non-ASCII stdin would raise.
exec ruby -E UTF-8 "$script" "$@"
