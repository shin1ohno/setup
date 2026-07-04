#!/bin/sh
# memory-keeper reconcile wrapper.
#
# LaunchDaemon runs this as UserName shin1ohno but does NOT set HOME, so we
# export it explicitly (needed to find keeper.env + ~/.claude credentials for
# `claude -p`). Source keeper.env for ES/Voyage/keeper config, then exec the
# reconcile tick. Guard: if keeper.env is absent (SSM auth not yet configured
# on a fresh host), exit 0 quietly so launchd does not log a failure loop.
export HOME=/Users/shin1ohno
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

KEEPER_ENV="$HOME/.config/memory-keeper/keeper.env"
[ -f "$KEEPER_ENV" ] || exit 0

set -a
. "$KEEPER_ENV"
set +a

exec /usr/bin/python3 /usr/local/lib/memory-keeper/reconcile.py
