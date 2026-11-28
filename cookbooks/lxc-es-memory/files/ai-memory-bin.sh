#!/bin/bash
# Compiled ai-memory binaries on CT 119 (ADR 0013 Decision 8, binary track).
#
# The recipe runs the subcommands in this order, each from its own execute, so a
# failed converge leaves a state the next converge finishes without manual work:
#
#   stage          download every pinned asset of release bin-<source_sha> into
#                  <base>/bin/.staging-<source_sha>/, check each against the
#                  sha256 in ai-memory-bin.pin, run `<asset> --version`, then
#                  rename the directory to <base>/bin/<source_sha>/. Any failure
#                  exits 1 before the rename, so `current`, DEPLOYED_SHA and the
#                  running units are untouched.
#   activate       point <base>/bin/current at <source_sha> with a rename, and
#                  keep the 3 newest binary directories.
#   restart-stale  restart each active unit whose main process does not run the
#                  file under <base>/bin/current. It does not depend on a notify,
#                  so an interrupted converge restarts the unit on the next one.
#
# check-staged, check-active and stale are the guards for the three executes.
# CT 119 holds no GitHub credential (ADR 0013 Decision 3): the download is
# anonymous and the sha256 from the setup pin is the only integrity check here.
# Provenance is verified in setup's CI (bin/check-ai-memory-pin).
#
# Usage:
#   ai-memory-bin.sh stage|check-staged <source_sha> <base> <name>=<sha256>...
#   ai-memory-bin.sh activate|check-active <source_sha> <base>
#   ai-memory-bin.sh restart-stale|stale <base> <unit>=<name>...
set -u
umask 022
export LC_ALL=C

KEEP=3
RELEASES=https://github.com/shin1ohno/ai-memory/releases/download

error() { echo "ERROR: ai-memory-bin: $*" >&2; exit 1; }
usage() { error "usage: see the header of $0"; }
hex() { case "$1" in "" | *[!0-9a-f]*) return 1 ;; esac; [ "${#1}" = "$2" ]; }
name_ok() { [[ "$1" =~ ^ai-memory-[a-z-]+$ ]]; }
unit_ok() { [[ "$1" =~ ^[A-Za-z0-9@_.-]+\.service$ ]]; }

[ "$#" -ge 2 ] || usage
mode=$1
shift

base_ok() {
  case "$1" in /*) ;; *) error "base must be absolute: $1" ;; esac
  [ ! -L "$1" ] || error "base is a symlink: $1"
  [ ! -L "$1/bin" ] || error "$1/bin is a symlink"
}

# <name>=<sha256> pairs -> NAMES and SUMS (parallel arrays), duplicates refused.
parse_assets() {
  NAMES=() SUMS=()
  [ "$#" -ge 1 ] || error "no asset given"
  local pair name sha seen
  for pair in "$@"; do
    name=${pair%%=*} sha=${pair#*=}
    name_ok "$name" || error "bad asset name: $name"
    hex "$sha" 64 || error "bad sha256 for $name"
    for seen in "${NAMES[@]:-}"; do [ "$seen" != "$name" ] || error "duplicate asset: $name"; done
    NAMES+=("$name") SUMS+=("$sha")
  done
}

# The directory holds exactly the pinned assets, each a regular 755 file with the
# pinned sha256, plus the .SHA256SUMS this script wrote.
verify_dir() {
  local dir=$1 i extra
  [ -d "$dir" ] && [ ! -L "$dir" ] || { echo "$dir is not a directory" >&2; return 1; }
  for i in "${!NAMES[@]}"; do
    [ -f "$dir/${NAMES[$i]}" ] && [ ! -L "$dir/${NAMES[$i]}" ] || { echo "${NAMES[$i]} is not a regular file" >&2; return 1; }
    [ -z "$(find "$dir/${NAMES[$i]}" -prune ! -perm 755)" ] || { echo "${NAMES[$i]} is not mode 755" >&2; return 1; }
  done
  (cd "$dir" && sha256sum --check --strict --quiet .SHA256SUMS) >&2 || { echo "sha256 mismatch in $dir" >&2; return 1; }
  extra=$(find "$dir" -mindepth 1 -maxdepth 1 ! -name .SHA256SUMS | while IFS= read -r f; do
    f=${f##*/}; keep=0
    for n in "${NAMES[@]}"; do [ "$n" != "$f" ] || keep=1; done
    [ "$keep" = 1 ] || echo "$f"
  done)
  [ -z "$extra" ] || { echo "unexpected files in $dir: $extra" >&2; return 1; }
  # The sums file must list the pinned values, not whatever was downloaded.
  [ "$(cat "$dir/.SHA256SUMS")" = "$(sums_body)" ] || { echo "$dir/.SHA256SUMS differs from the pin" >&2; return 1; }
}

sums_body() {
  local i
  for i in "${!NAMES[@]}"; do printf '%s  %s\n' "${SUMS[$i]}" "${NAMES[$i]}"; done
}

case "$mode" in
stage | check-staged)
  [ "$#" -ge 3 ] || usage
  src=$1 base=${2%/}
  shift 2
  hex "$src" 40 || error "source_sha is not 40 hex: $src"
  base_ok "$base"
  parse_assets "$@"
  dest=$base/bin/$src
  if [ "$mode" = check-staged ]; then verify_dir "$dest" 2>/dev/null; exit $?; fi
  if verify_dir "$dest" 2>/dev/null; then echo "PASS  binaries for $src already staged"; exit 0; fi

  mkdir -p "$base/bin" || error "cannot create $base/bin"
  staging=$base/bin/.staging-$src
  rm -rf "$staging" && mkdir "$staging" || error "cannot create $staging"
  trap '[ -z "$staging" ] || rm -rf "$staging"' EXIT
  for i in "${!NAMES[@]}"; do
    url=$RELEASES/bin-$src/${NAMES[$i]}
    curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
      --retry 3 --retry-all-errors --max-time 300 -o "$staging/${NAMES[$i]}" "$url" ||
      error "download failed: $url; current deployment kept"
    chmod 755 "$staging/${NAMES[$i]}" || error "cannot chmod ${NAMES[$i]}"
  done
  sums_body > "$staging/.SHA256SUMS" || error "cannot write the sums file"
  verify_dir "$staging" || error "staged binaries failed verification; current deployment kept"
  # Executed only after the pinned digest authenticated it. An illegal
  # instruction (for example AVX2 on CT 119) fails here, before activation.
  for n in "${NAMES[@]}"; do
    "$staging/$n" --version >/dev/null 2>&1 < /dev/null || error "$n --version failed; current deployment kept"
  done
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    # A directory that failed verification under the same name. `current` may
    # point at it, so it moves aside instead of being removed first.
    stale=$base/bin/.stale-$src.$$
    mv -T "$dest" "$stale" || error "cannot move the old $dest aside"
  fi
  mv -T "$staging" "$dest" || error "cannot rename $staging"
  staging=
  [ -z "${stale:-}" ] || rm -rf "$stale"
  verify_dir "$dest" || error "receiving state failed verification"
  echo "PASS  binaries for $src staged at $dest"
  ;;

activate | check-active)
  [ "$#" = 2 ] || usage
  src=$1 base=${2%/}
  hex "$src" 40 || error "source_sha is not 40 hex: $src"
  base_ok "$base"
  bin=$base/bin
  if [ "$mode" = check-active ]; then [ -L "$bin/current" ] && [ "$(readlink "$bin/current")" = "$src" ]; exit $?; fi
  [ -d "$bin/$src" ] && [ ! -L "$bin/$src" ] || error "$bin/$src is not staged"
  rm -f "$bin/current.tmp"
  ln -s "$src" "$bin/current.tmp" && mv -T "$bin/current.tmp" "$bin/current" || error "cannot switch current"
  # Keep the KEEP newest binary directories; current is always one of them.
  # Leftover staging and stale directories go too.
  n=0
  while IFS= read -r d; do
    d=${d%/}; d=${d##*/}
    hex "$d" 40 || continue
    if [ "$d" = "$src" ]; then n=$((n + 1)); continue; fi
    n=$((n + 1))
    [ "$n" -le "$KEEP" ] || rm -rf "${bin:?}/$d"
  done < <(ls -1dt "$bin"/*/ 2>/dev/null)
  find "$bin" -mindepth 1 -maxdepth 1 \( -name '.staging-*' -o -name '.stale-*' \) -exec rm -rf {} +
  echo "PASS  current -> $src"
  ;;

restart-stale | stale)
  [ "$#" -ge 2 ] || usage
  base=${1%/}
  shift
  base_ok "$base"
  found=1
  for pair in "$@"; do
    unit=${pair%%=*} name=${pair#*=}
    unit_ok "$unit" || error "bad unit: $unit"
    name_ok "$name" || error "bad asset name: $name"
    systemctl is-active --quiet "$unit" || continue
    pid=$(systemctl show -p MainPID --value "$unit")
    case "$pid" in "" | 0 | *[!0-9]*) continue ;; esac
    running=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
    want=$(readlink -f "$base/bin/current/$name" 2>/dev/null || true)
    [ -n "$want" ] || error "$base/bin/current/$name does not resolve"
    [ "$running" != "$want" ] || continue
    found=0
    [ "$mode" = stale ] && { echo "$unit runs ${running:-?}, current is $want"; continue; }
    systemctl restart "$unit" || error "cannot restart $unit"
    echo "PASS  restarted $unit (was ${running:-?})"
  done
  # stale is a guard: 0 means at least one unit needs a restart.
  if [ "$mode" = stale ]; then exit "$found"; fi
  ;;

*) usage ;;
esac
