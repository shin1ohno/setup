#!/bin/bash
# Verified single-binary placement; bash 3.2, no Python or network in check.
# ADR 0015. Downloads fail soft; integrity and execution failures fail closed.
set -u
umask 022
usage() { echo 'usage: deploy-binary.sh deploy|check <40-hex pin> <64-hex sha256> <target> <absolute share_dir>' >&2; exit 2; }
[ "$#" = 5 ] || usage
mode=$1 pin=$2 sha=$3 target=$4 share=${5%/}
case "$mode" in deploy|check) ;; *) usage ;; esac
case "$share" in /*) ;; *) usage ;; esac
error() { echo "ERROR: session-search binary: $*" >&2; exit 1; }
hex() { case "$1" in *[!0-9a-f]*) return 1 ;; esac; [ "${#1}" = "$2" ]; }
hex "$pin" 40 && hex "$sha" 64 || error 'invalid pin or sha256'
case "$target" in x86_64-unknown-linux-gnu|aarch64-unknown-linux-gnu|aarch64-apple-darwin) ;; *) error 'unsupported target' ;; esac
[ -n "$share" ] && [ ! -L "$share" ] && [ ! -L "$share/bin" ] || error 'unsafe share directory'
binary=$share/bin/ccs-$pin
marker=$share/DEPLOYED_BINARY
hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}
verify() {
  [ -f "$1" ] && [ ! -L "$1" ] || { echo 'not a regular binary' >&2; return 1; }
  [ -z "$(find "$1" -prune ! -perm 755)" ] || { echo 'binary mode is not 755' >&2; return 1; }
  [ "$(hash "$1")" = "$sha" ] || { echo 'sha256 mismatch' >&2; return 1; }
  # This executable was authenticated by the pinned digest before execution.
  local info commit built_target
  info=$("$1" _buildinfo) || { echo '_buildinfo execution failed' >&2; return 1; }
  commit=$(printf '%s\n' "$info" | sed -n 's/^.*"commit":"\([0-9a-f]*\)".*$/\1/p')
  built_target=$(printf '%s\n' "$info" | sed -n 's/^.*"target":"\([a-z0-9_-]*\)".*$/\1/p')
  [ "$commit" = "$pin" ] && [ "$built_target" = "$target" ] || { echo '_buildinfo identity mismatch' >&2; return 1; }
}
matches() {
  [ -f "$marker" ] && [ ! -L "$marker" ] && [ "$(cat "$marker")" = "$sha $pin $target" ] && verify "$binary"
}
if [ "$mode" = check ]; then matches; exit $?; fi
if matches 2>/dev/null; then echo "PASS binary already deployed $pin"; exit 0; fi
mkdir -p "$share/bin" || error 'cannot create binary directory'
previous=''
if [ -f "$marker" ] && [ ! -L "$marker" ]; then
  previous=$(cut -d' ' -f2 "$marker")
  hex "$previous" 40 || previous=''
fi
staging='' record=''
cleanup() { [ -z "$staging" ] || rm -f "$staging"; [ -z "$record" ] || rm -f "$record"; return 0; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
# A verified older binary can be restored without a download (RT1 X -> Y -> X).
if ! verify "$binary" 2>/dev/null; then
  staging=$(mktemp "$share/bin/.ccs.XXXXXX") || error 'cannot stage binary'
  url="https://github.com/shin1ohno/session-search/releases/download/ccs-$pin/ccs-$target"
  if ! curl -q -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --max-time 120 "$url" -o "$staging"; then
    echo 'WARN: session-search binary: download failed; keeping current deployment' >&2
    exit 0
  fi
  [ "$(hash "$staging")" = "$sha" ] || error 'sha256 mismatch; keeping current deployment'
  chmod 755 "$staging" || error 'cannot set binary mode'
  verify "$staging" || error 'staged binary failed verification; keeping current deployment'
  mv -f "$staging" "$binary" || error 'cannot place binary'
  staging=''
fi
record=$(mktemp "$share/.binary-record.XXXXXX") || error 'cannot stage record'
printf '%s %s %s\n' "$sha" "$pin" "$target" > "$record" || error 'cannot write record'
chmod 644 "$record" && mv -f "$record" "$marker" || error 'cannot place record'
record=''
for file in "$share"/bin/ccs-*; do
  [ -e "$file" ] || [ -L "$file" ] || continue
  name=${file##*/ccs-}
  hex "$name" 40 || continue
  [ "$name" = "$pin" ] || [ "$name" = "$previous" ] || rm -f "$file" || error 'cannot remove old binary'
done
matches || error 'receiving state failed check'
echo "PASS binary deployed $pin $target"
