#!/usr/bin/env bash
# Copy the fixtures into the run directory. Ledger and envelope paths are
# absolute, so the @@STATE@@ placeholder becomes this run's ./state.
set -eu
cp -R "$(dirname "$0")/files/." .
state="$(pwd -P)/state"
grep -rl '@@STATE@@' state 2>/dev/null | while IFS= read -r f; do
  sed "s#@@STATE@@#$state#g" "$f" > "$f.tmp"
  mv "$f.tmp" "$f"
done
