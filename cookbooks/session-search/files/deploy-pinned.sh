#!/bin/bash
# Deploy the ccs package from shin1ohno/session-search at a pinned SHA (ADR 0014).
#
#   deploy-pinned.sh deploy <40-hex pin> <absolute share_dir>
#   deploy-pinned.sh check  <40-hex pin> <absolute share_dir>
#
# Layout under <share_dir>:
#   src/              git repository the pin is fetched into
#   ccs/              the deployed package (ccs/* plus the two vendored modules)
#   DEPLOYED_SHA      the pin the package was verified against
#   DEPLOYED_MANIFEST one "<oid> ccs/<name>" line per deployed file
#
# Exit status of deploy:
#   0  deployed, already current, or the fetch failed (WARN; the current
#      deployment stays, and with no earlier one nothing is installed)
#   1  integrity failure or local error such as no git or an unwritable
#      share_dir (ERROR; a failure before the swap leaves the deployment as it was)
#   2  usage
# Exit status of check: 0 only if the deployment matches the pin. No network.
#
# Runs on the macOS system bash, so this stays bash 3.2 compatible and needs
# nothing beyond git and POSIX tools. SESSION_SEARCH_ORIGIN exists for tests.

set -u
umask 022

usage() {
  echo "usage: deploy-pinned.sh deploy|check <40-hex pin> <absolute share_dir>" >&2
  exit 2
}

[ "$#" -eq 3 ] || usage
mode=$1
pin=$2
share=$3

case "$mode" in deploy | check) ;; *) usage ;; esac
case "$share" in /*) ;; *) usage ;; esac
share=${share%/}

error() {
  echo "ERROR: session-search: $*" >&2
  exit 1
}

warn() {
  echo "WARN: session-search: $*" >&2
}

is_oid() {
  case "$1" in
    *[!0123456789abcdef]*) return 1 ;;
  esac
  [ "${#1}" -eq 40 ]
}

is_oid "$pin" || error "malformed pin '$pin' (want 40 lowercase hex characters)"
command -v git >/dev/null 2>&1 || error "git is not on PATH"

# A root apply may start this from a directory the target user cannot read, and
# git refuses to run from one. Every path below is absolute.
cd / || error "cannot change to /"

# The user's and system's config cannot change where or what is fetched, and
# nothing waits for credentials or hangs the converge on a stalled connection.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=60
unset GIT_ASKPASS SSH_ASKPASS
# shellcheck disable=SC2046 # one variable name per word
unset $(git rev-parse --local-env-vars 2>/dev/null)

origin=${SESSION_SEARCH_ORIGIN:-https://github.com/shin1ohno/session-search.git}
src=$share/src
pkg=$share/ccs
previous=$share/.ccs.previous
sha_file=$share/DEPLOYED_SHA
manifest=$share/DEPLOYED_MANIFEST

# --- check -------------------------------------------------------------------

mismatch() {
  echo "session-search: not deployed at $pin: $*" >&2
  return 1
}

deployment_matches() {
  local oid path file got listed wrong_mode

  [ -f "$sha_file" ] || { mismatch "no DEPLOYED_SHA"; return 1; }
  [ "$(cat "$sha_file")" = "$pin" ] || { mismatch "DEPLOYED_SHA differs"; return 1; }
  [ -s "$manifest" ] || { mismatch "no manifest"; return 1; }
  if [ ! -d "$pkg" ] || [ -L "$pkg" ]; then
    mismatch "no package directory"
    return 1
  fi

  while IFS=' ' read -r oid path; do
    is_oid "$oid" || { mismatch "malformed manifest line"; return 1; }
    case "$path" in
      ccs/*/* | ccs/) mismatch "malformed manifest path $path"; return 1 ;;
      ccs/*) ;;
      *) mismatch "malformed manifest path $path"; return 1 ;;
    esac
    file=$share/$path
    if [ ! -f "$file" ] || [ -L "$file" ]; then
      mismatch "$path is missing"
      return 1
    fi
    got=$(git hash-object --no-filters "$file") || { mismatch "cannot hash $path"; return 1; }
    [ "$got" = "$oid" ] || { mismatch "$path has different content"; return 1; }
  done <"$manifest"

  listed=$(cut -d' ' -f2- "$manifest")
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if ! printf '%s\n' "$listed" | grep -qxF "${file#"$share"/}"; then
      mismatch "extra file ${file#"$share"/}"
      return 1
    fi
  done <<EOF
$(find "$pkg" -name '*.py')
EOF

  wrong_mode=$(find "$pkg" -maxdepth 0 ! -perm 755)
  [ -z "$wrong_mode" ] || { mismatch "package directory mode is not 755"; return 1; }
  wrong_mode=$(find "$pkg" -maxdepth 1 -type f ! -perm 644)
  [ -z "$wrong_mode" ] || { mismatch "a package file mode is not 644"; return 1; }
  return 0
}

if [ "$mode" = check ]; then
  deployment_matches
  exit $?
fi

# --- deploy ------------------------------------------------------------------

mkdir -p "$share" || error "cannot create $share"

# An interrupted swap leaves the old package here. Put it back first.
if [ -d "$previous" ] && [ ! -e "$pkg" ] && [ ! -L "$pkg" ]; then
  mv "$previous" "$pkg" || error "cannot restore $pkg"
fi
rm -rf "$previous" "$share"/.ccs.staging.* "$share"/.deploy.tmp.*

# Output is suppressed: on a first deploy the mismatch is the normal case.
if deployment_matches 2>/dev/null; then
  echo "session-search: already deployed at $pin"
  exit 0
fi

staging=""
tree=""
manifest_tmp=""
sha_tmp=""

cleanup() {
  [ -z "$staging" ] || rm -rf "$staging"
  for temporary in "$tree" "$manifest_tmp" "$sha_tmp"; do
    [ -z "$temporary" ] || rm -f "$temporary"
  done
  if [ -d "$previous" ] && [ ! -e "$pkg" ] && [ ! -L "$pkg" ]; then
    mv "$previous" "$pkg"
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [ ! -d "$src/.git" ]; then
  mkdir -p "$src" || error "cannot create $src"
  git init -q "$src" || error "cannot initialise $src"
fi
git -C "$src" config remote.origin.url "$origin" || error "cannot set the origin of $src"
mkdir -p "$src/.git/info" || error "cannot create $src/.git/info"
echo '* -text -eol -ident -filter -working-tree-encoding' >"$src/.git/info/attributes" ||
  error "cannot write $src/.git/info/attributes"

if ! git -C "$src" fetch -q --no-tags --no-recurse-submodules origin \
  '+refs/heads/main:refs/remotes/origin/main'; then
  warn "cannot fetch $origin; leaving the current deployment untouched"
  exit 0
fi

# Status 1 is "not an ancestor", 128 is "commit not fetched". An unmerged
# branch's SHA is the second, because only main is fetched. Both refuse the pin.
git -C "$src" merge-base --is-ancestor "$pin" refs/remotes/origin/main 2>/dev/null ||
  error "pin $pin is not an ancestor of main of $origin; deployment left untouched"

tree=$(mktemp "$share/.deploy.tmp.XXXXXX") || error "cannot create a temporary file in $share"
manifest_tmp=$(mktemp "$share/.deploy.tmp.XXXXXX") || error "cannot create a temporary file in $share"
sha_tmp=$(mktemp "$share/.deploy.tmp.XXXXXX") || error "cannot create a temporary file in $share"
staging=$(mktemp -d "$share/.ccs.staging.XXXXXX") || error "cannot create a staging directory in $share"
chmod 755 "$staging" || error "cannot set the mode of $staging"

git -C "$src" ls-tree -r -z "$pin" -- ccs vendor/memory-mcp >"$tree" ||
  error "cannot list the tree at $pin; deployment left untouched"

package_files=0
vendored_files=0
while IFS= read -r -d '' record; do
  meta=${record%%$'\t'*}
  path=${record#*$'\t'}
  file_mode=${meta%% *}
  oid=${meta##* }

  case "$path" in
    ccs/*)
      name=${path#ccs/}
      package_files=$((package_files + 1))
      ;;
    vendor/memory-mcp/session_redact.py | vendor/memory-mcp/session_codex.py)
      name=${path##*/}
      vendored_files=$((vendored_files + 1))
      ;;
    *) continue ;;
  esac

  case "$file_mode" in
    100644 | 100755) ;;
    *) error "$path at $pin is not a regular file (mode $file_mode); deployment left untouched" ;;
  esac
  # Lines of the manifest are "<oid> ccs/<name>", and a tree path is untrusted
  # input to the rename below.
  case "$name" in
    "" | .* | */* | *[!A-Za-z0-9_.-]*)
      error "unexpected path $path at $pin; deployment left untouched"
      ;;
  esac
  [ ! -e "$staging/$name" ] || error "$name appears twice at $pin; deployment left untouched"

  # cat-file writes the blob as stored: no attribute, filter or eol conversion.
  git -C "$src" cat-file blob "$oid" >"$staging/$name" ||
    error "cannot read $path at $pin; deployment left untouched"
  chmod 644 "$staging/$name" || error "cannot set the mode of $name"
  got=$(git hash-object --no-filters "$staging/$name") ||
    error "cannot hash the staged $name; deployment left untouched"
  [ "$got" = "$oid" ] ||
    error "OID mismatch for $path at $pin (want $oid, staged $got); deployment left untouched"
  printf '%s ccs/%s\n' "$oid" "$name" >>"$manifest_tmp" || error "cannot write the manifest"
done <"$tree"

[ "$package_files" -gt 0 ] || error "no ccs/ files at $pin; deployment left untouched"
[ "$vendored_files" -eq 2 ] ||
  error "the vendored redactor and codex adapter are not both at $pin; deployment left untouched"

# Everything is verified. Only now is the current deployment replaced.
if [ -e "$pkg" ] || [ -L "$pkg" ]; then
  mv "$pkg" "$previous" || error "cannot move the current package aside"
fi
mv "$staging" "$pkg" || error "cannot move the staged package into place"
staging=""
rm -rf "$previous"

# DEPLOYED_SHA goes last, so a run that stops earlier fails check and repeats.
chmod 644 "$manifest_tmp" "$sha_tmp" || error "cannot set the mode of the deployment records"
mv -f "$manifest_tmp" "$manifest" || error "cannot write $manifest"
manifest_tmp=""
printf '%s\n' "$pin" >"$sha_tmp" || error "cannot write the deployed SHA"
mv -f "$sha_tmp" "$sha_file" || error "cannot write $sha_file"
sha_tmp=""

echo "session-search: deployed $pin"
