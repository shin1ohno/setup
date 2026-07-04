#!/bin/sh
# memory-keeper nightly consolidation wrapper.
#
# Same posture as memory-keeper-run.sh (LaunchDaemon, UserName shin1ohno, no
# HOME set). Exports HOME + PATH, sources keeper.env, then exec's the nightly
# consolidation job. Guard: skip quietly when keeper.env is absent.
export HOME=/Users/shin1ohno
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

KEEPER_ENV="$HOME/.config/memory-keeper/keeper.env"
[ -f "$KEEPER_ENV" ] || exit 0

set -a
. "$KEEPER_ENV"
set +a

exec /usr/bin/python3 /usr/local/lib/memory-keeper/consolidate.py
