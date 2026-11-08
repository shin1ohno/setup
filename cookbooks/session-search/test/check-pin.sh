#!/usr/bin/env bash
# CI guardrail for the pinned shin1ohno/session-search (ADR 0014): the pin file
# is one 40-hex line and the SHA is an ancestor of main, so an unmerged branch
# commit cannot reach a host.
#
# Usage: cookbooks/session-search/test/check-pin.sh [PIN_FILE]     # exit 1 on failure
# SESSION_SEARCH_ORIGIN overrides the URL for the hermetic test.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIN_FILE="${1:-$HERE/../session-search.pin}"
ORIGIN="${SESSION_SEARCH_ORIGIN:-https://github.com/shin1ohno/session-search.git}"
T=$(mktemp -d "${TMPDIR:-/tmp}/session-search-pin.XXXXXX")
trap 'rm -rf "$T"' EXIT

die() {
  echo "FAIL  $*" >&2
  exit 1
}

[ -f "$PIN_FILE" ] || die "$PIN_FILE does not exist"
[ "$(grep -c '' "$PIN_FILE")" -eq 1 ] || die "$PIN_FILE must hold exactly one line"
grep -Eqx '[0-9a-f]{40}' "$PIN_FILE" || die "$PIN_FILE is not a 40-hex SHA"
pin=$(cat "$PIN_FILE")

# Same isolation as deploy-pinned.sh: a url rewrite cannot change the transport.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
git -C "$T" init -q
git -C "$T" fetch -q --no-tags "$ORIGIN" +refs/heads/main:refs/remotes/origin/main ||
  die "main of $ORIGIN cannot be fetched anonymously"
git -C "$T" merge-base --is-ancestor "$pin" refs/remotes/origin/main 2>/dev/null ||
  die "pin $pin is not an ancestor of main of $ORIGIN"
echo "PASS  pin $pin is on main of $ORIGIN"
