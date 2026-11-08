#!/bin/bash
# Hermetic test of files/deploy-pinned.sh and test/check-pin.sh: a private HOME
# under $TMPDIR, a local bare repository as origin, no network.
#
# /bin/bash on purpose: on macOS that is 3.2, the shell the script runs under.
#
# Usage: cookbooks/session-search/test/test-deploy-pinned.sh     # exit 1 on failure
# DEPLOY_SCRIPT runs the cases against another copy of the script.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Run before replacing HOME: Ruby/Python tool-manager shims need the real HOME.
ruby "$HERE/test-launcher.rb" || exit 1
SCRIPT="${DEPLOY_SCRIPT:-$HERE/../files/deploy-pinned.sh}"
CHECK_PIN="$HERE/check-pin.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/deploy-pinned-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
mkdir -p "$HOME"
unset XDG_CONFIG_HOME GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

ORIGIN="$WORK/origin.git"
TREE="$WORK/tree"
OUT="$WORK/last.out"
SNAP_A="$WORK/snapshot.a"
SNAP_B="$WORK/snapshot.b"
REAL_GIT=$(command -v git)
FAILED=0

echo "bash ${BASH_VERSION}; $(git --version)"

pass() { echo "PASS  $*"; }
fail() {
  echo "FAIL  $*"
  sed 's/^/      /' "$OUT" 2>/dev/null
  FAILED=1
}

# Fixture git: config-free, so the fixture does not depend on the test's HOME.
fx() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$REAL_GIT" \
    -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
    -c core.safecrlf=false "$@"
}

commit_all() {
  fx -C "$TREE" add -A
  fx -C "$TREE" commit -q -m "$1"
  fx -C "$TREE" rev-parse HEAD
}

deploy() {
  SESSION_SEARCH_ORIGIN="$ORIGIN" /bin/bash "$SCRIPT" deploy "$1" "$2" >"$OUT" 2>&1
}

check() {
  /bin/bash "$SCRIPT" check "$1" "$2" >"$OUT" 2>&1
}

# inode, mode, size and checksum of everything the deployment consists of.
# src/ is left out because a failed attempt may add objects there, and so is the
# share directory itself: a failed attempt creates and removes temporary files
# in it, which moves its mtime without changing the deployment.
snapshot() {
  (
    cd "$1" || exit 1
    find . -mindepth 1 -path ./src -prune -o -print | LC_ALL=C sort | while IFS= read -r p; do
      ls -lid "$p"
      if [ -f "$p" ]; then cksum <"$p"; fi
    done
  )
}

nothing_installed() {
  [ ! -e "$1/ccs" ] && [ ! -e "$1/DEPLOYED_SHA" ] && [ ! -e "$1/DEPLOYED_MANIFEST" ]
}

no_leftovers() {
  [ -z "$(find "$1" -mindepth 1 -maxdepth 1 -name '.*')" ]
}

# --- fixture -----------------------------------------------------------------

fx init -q --bare -b main "$ORIGIN"
fx init -q -b main "$TREE"
fx -C "$TREE" config remote.origin.url "$ORIGIN"
mkdir -p "$TREE/ccs" "$TREE/tests" "$TREE/vendor/memory-mcp"

# A checkout would rewrite both of these (eol=crlf, ident). The deployment must not.
printf 'ccs/cli.py ident\nccs/eol.py text eol=crlf\n' >"$TREE/.gitattributes"
printf '# package\n' >"$TREE/ccs/__init__.py"
printf '# $Id$\nVERSION = "a"\n' >"$TREE/ccs/cli.py"
printf 'one = 1\ntwo = 2\n' >"$TREE/ccs/eol.py"
printf 'REDACT = "a"\n' >"$TREE/vendor/memory-mcp/session_redact.py"
printf 'CODEX = "a"\n' >"$TREE/vendor/memory-mcp/session_codex.py"
printf 'setup@abc\n' >"$TREE/vendor/memory-mcp/SOURCE"
printf 'TEST = 1\n' >"$TREE/tests/test_cli.py"
PIN_A=$(commit_all "first")

printf '# $Id$\nVERSION = "b"\n' >"$TREE/ccs/cli.py"
PIN_B=$(commit_all "second")
fx -C "$TREE" push -q origin main

fx -C "$TREE" checkout -q -b side "$PIN_A"
printf 'UNREVIEWED = 1\n' >"$TREE/ccs/side.py"
PIN_SIDE=$(commit_all "unmerged branch")
fx -C "$TREE" push -q origin side

fx -C "$TREE" checkout -q main

# --- first deploy and re-run --------------------------------------------------

SHARE="$WORK/share"
if deploy "$PIN_A" "$SHARE" && check "$PIN_A" "$SHARE"; then
  pass "first deploy succeeds and check passes"
else
  fail "first deploy or its check"
fi

if [ "$(cat "$SHARE/DEPLOYED_SHA")" = "$PIN_A" ]; then
  pass "DEPLOYED_SHA records the pin"
else
  fail "DEPLOYED_SHA records the pin"
fi

if [ "$(wc -l <"$SHARE/DEPLOYED_MANIFEST" | tr -d ' ')" -eq 5 ]; then
  pass "manifest has one line per installed file"
else
  fail "manifest has one line per installed file"
fi

if [ -f "$SHARE/ccs/session_redact.py" ] && [ -f "$SHARE/ccs/session_codex.py" ]; then
  pass "vendored modules are installed inside the package"
else
  fail "vendored modules are installed inside the package"
fi

if [ ! -e "$SHARE/ccs/SOURCE" ] && [ ! -e "$SHARE/tests" ] && [ ! -e "$SHARE/ccs/test_cli.py" ]; then
  pass "tests/ and SOURCE are not installed"
else
  fail "tests/ and SOURCE are not installed"
fi

if [ -z "$(find "$SHARE/ccs" -type f ! -perm 644)" ] && [ -z "$(find "$SHARE/ccs" -type d ! -perm 755)" ]; then
  pass "modes are 755 for the directory and 644 for files"
else
  fail "modes are 755 for the directory and 644 for files"
fi

if no_leftovers "$SHARE"; then
  pass "no staging or temporary files remain"
else
  fail "no staging or temporary files remain"
fi

if cmp -s "$SHARE/ccs/eol.py" <(fx -C "$TREE" cat-file blob "$PIN_A:ccs/eol.py") &&
  grep -q '^# \$Id\$$' "$SHARE/ccs/cli.py"; then
  pass "eol and ident attributes do not change the deployed bytes"
else
  fail "eol and ident attributes do not change the deployed bytes"
fi

snapshot "$SHARE" >"$SNAP_A"
: >"$WORK/sentinel"
sleep 1
if deploy "$PIN_A" "$SHARE"; then
  snapshot "$SHARE" >"$SNAP_B"
  if cmp -s "$SNAP_A" "$SNAP_B" && [ -z "$(find "$SHARE" -newer "$WORK/sentinel")" ] && check "$PIN_A" "$SHARE"; then
    pass "second deploy changes nothing and check still passes"
  else
    fail "second deploy changes nothing and check still passes"
  fi
else
  fail "second deploy exits 0"
fi

# --- pin move -----------------------------------------------------------------

if check "$PIN_B" "$SHARE"; then
  fail "check must fail for a different pin"
else
  pass "check fails for a different pin"
fi

if deploy "$PIN_B" "$SHARE" && check "$PIN_B" "$SHARE" && grep -q 'VERSION = "b"' "$SHARE/ccs/cli.py"; then
  pass "moving the pin deploys the new content"
else
  fail "moving the pin deploys the new content"
fi

# --- local drift --------------------------------------------------------------

drift_case() { # <description> <shell command run in the package directory>
  (cd "$SHARE/ccs" && eval "$2")
  if check "$PIN_B" "$SHARE"; then
    fail "drift ($1): check must fail"
  elif deploy "$PIN_B" "$SHARE" && check "$PIN_B" "$SHARE"; then
    pass "drift ($1): check fails and deploy repairs it"
  else
    fail "drift ($1): deploy must repair it"
  fi
}

drift_case "changed bytes" 'printf "x" >>cli.py'
drift_case "deleted file" 'rm session_redact.py'
drift_case "extra module" 'printf "EVIL = 1\n" >planted.py'
drift_case "changed file mode" 'chmod 600 cli.py'
drift_case "changed directory mode" 'chmod 700 .'

mkdir -p "$SHARE/ccs/__pycache__"
printf 'bytecode' >"$SHARE/ccs/__pycache__/cli.cpython-313.pyc"
if check "$PIN_B" "$SHARE"; then
  pass "bytecode written at run time is not drift"
else
  fail "bytecode written at run time is not drift"
fi

# --- tampered bytes -----------------------------------------------------------

FAKE="$WORK/fakebin"
mkdir -p "$FAKE"
cat >"$FAKE/git" <<EOF
#!/bin/bash
for a in "\$@"; do
  if [ "\$a" = cat-file ]; then
    "$REAL_GIT" "\$@"
    rc=\$?
    printf 'T'
    : >"$WORK/fake-git-tampered"
    exit \$rc
  fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod 755 "$FAKE/git"

snapshot "$SHARE" >"$SNAP_A"
PATH="$FAKE:$PATH" SESSION_SEARCH_ORIGIN="$ORIGIN" /bin/bash "$SCRIPT" deploy "$PIN_A" "$SHARE" >"$OUT" 2>&1
rc=$?
snapshot "$SHARE" >"$SNAP_B"
if [ "$rc" -ne 0 ] && [ -f "$WORK/fake-git-tampered" ] && grep -q '^ERROR: .*OID mismatch' "$OUT" &&
  cmp -s "$SNAP_A" "$SNAP_B" && no_leftovers "$SHARE"; then
  pass "tampered bytes: ERROR, non-zero, deployment unchanged"
  sed 's/^/      /' "$OUT"
else
  fail "tampered bytes (rc=$rc)"
fi
if check "$PIN_B" "$SHARE"; then
  pass "tampered bytes: the earlier deployment still verifies"
else
  fail "tampered bytes: the earlier deployment still verifies"
fi

# --- non-ancestor pin ---------------------------------------------------------

snapshot "$SHARE" >"$SNAP_A"
deploy "$PIN_SIDE" "$SHARE"
rc=$?
snapshot "$SHARE" >"$SNAP_B"
if [ "$rc" -ne 0 ] && grep -q '^ERROR: .*not an ancestor' "$OUT" && cmp -s "$SNAP_A" "$SNAP_B"; then
  pass "unmerged branch pin: ERROR, non-zero, deployment unchanged"
  sed 's/^/      /' "$OUT"
else
  fail "unmerged branch pin (rc=$rc)"
fi

# Main is rewound past a commit src/ already holds: the object exists locally
# and only the ancestry test can refuse it.
REWOUND="$WORK/share-rewound"
deploy "$PIN_A" "$REWOUND"
deploy "$PIN_B" "$REWOUND"
deploy "$PIN_A" "$REWOUND"
fx -C "$TREE" push -q --force origin "$PIN_A:refs/heads/main"
snapshot "$REWOUND" >"$SNAP_A"
deploy "$PIN_B" "$REWOUND"
rc=$?
snapshot "$REWOUND" >"$SNAP_B"
if [ "$rc" -ne 0 ] && grep -q '^ERROR: .*not an ancestor' "$OUT" && cmp -s "$SNAP_A" "$SNAP_B"; then
  pass "pin no longer on main: ERROR, non-zero, deployment unchanged"
  sed 's/^/      /' "$OUT"
else
  fail "pin no longer on main (rc=$rc)"
fi
fx -C "$TREE" push -q --force origin "$PIN_B:refs/heads/main"

# --- malformed pin ------------------------------------------------------------

snapshot "$SHARE" >"$SNAP_A"
for bad in main "${PIN_A%?}" "${PIN_A}0" "$(printf '%s' "$PIN_A" | tr 'a-f' 'A-F')" '--upload-pack=x'; do
  deploy "$bad" "$SHARE"
  rc=$?
  snapshot "$SHARE" >"$SNAP_B"
  if [ "$rc" -ne 0 ] && grep -q '^ERROR: .*malformed pin' "$OUT" && cmp -s "$SNAP_A" "$SNAP_B"; then
    pass "malformed pin '$bad': ERROR, non-zero, deployment unchanged"
  else
    fail "malformed pin '$bad' (rc=$rc)"
  fi
done

# --- unusable trees -----------------------------------------------------------

bad_tree_case() { # <description> <expected ERROR text> <shell command run in the tree>
  fx -C "$TREE" checkout -q -B bad-tree main
  (cd "$TREE" && eval "$3")
  local bad_pin
  bad_pin=$(commit_all "bad tree: $1")
  fx -C "$TREE" push -q --force origin "$bad_pin:refs/heads/main"
  snapshot "$SHARE" >"$SNAP_A"
  deploy "$bad_pin" "$SHARE"
  local rc=$?
  snapshot "$SHARE" >"$SNAP_B"
  if [ "$rc" -ne 0 ] && grep -q "^ERROR: .*$2" "$OUT" && cmp -s "$SNAP_A" "$SNAP_B"; then
    pass "$1: ERROR, non-zero, deployment unchanged"
  else
    fail "$1 (rc=$rc)"
  fi
  fx -C "$TREE" push -q --force origin "$PIN_B:refs/heads/main"
  fx -C "$TREE" checkout -q main
  fx -C "$TREE" reset -q --hard "$PIN_B"
}

bad_tree_case "symlink in the package" "not a regular file" 'ln -s /etc/passwd ccs/link.py'
bad_tree_case "nested path in the package" "unexpected path" 'mkdir ccs/sub && printf "x\n" >ccs/sub/a.py'
bad_tree_case "vendored file missing" "not both" 'rm vendor/memory-mcp/session_codex.py'
bad_tree_case "vendored name collides with the package" "appears twice" 'printf "x\n" >ccs/session_redact.py'

# --- fetch failure ------------------------------------------------------------

UNREACHABLE="$WORK/does-not-exist.git"

snapshot "$SHARE" >"$SNAP_A"
SESSION_SEARCH_ORIGIN="$UNREACHABLE" /bin/bash "$SCRIPT" deploy "$PIN_A" "$SHARE" >"$OUT" 2>&1
rc=$?
snapshot "$SHARE" >"$SNAP_B"
if [ "$rc" -eq 0 ] && grep -q '^WARN: ' "$OUT" && cmp -s "$SNAP_A" "$SNAP_B"; then
  pass "fetch failure with an earlier deployment: WARN, exit 0, unchanged"
else
  fail "fetch failure with an earlier deployment (rc=$rc)"
fi

FRESH="$WORK/share-fresh"
SESSION_SEARCH_ORIGIN="$UNREACHABLE" /bin/bash "$SCRIPT" deploy "$PIN_A" "$FRESH" >"$OUT" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q '^WARN: ' "$OUT" && nothing_installed "$FRESH"; then
  pass "fetch failure with no deployment: WARN, exit 0, nothing installed"
else
  fail "fetch failure with no deployment (rc=$rc)"
fi
if check "$PIN_A" "$FRESH"; then
  fail "check must fail when nothing is installed"
else
  pass "check fails when nothing is installed"
fi

# check needs no network: the origin is unreachable through the whole call.
if SESSION_SEARCH_ORIGIN="$UNREACHABLE" /bin/bash "$SCRIPT" check "$PIN_B" "$SHARE" >"$OUT" 2>&1; then
  pass "check passes with the origin unreachable"
else
  fail "check passes with the origin unreachable"
fi

# --- hostile global git config ------------------------------------------------

printf '* filter=hostile\n' >"$HOME/attributes"
cat >"$HOME/.gitconfig" <<EOF
[url "file:///nonexistent/rewritten.git"]
	insteadOf = $ORIGIN
[core]
	autocrlf = true
	attributesFile = $HOME/attributes
[filter "hostile"]
	clean = sed s/a/b/
	smudge = sed s/a/b/
	required = true
EOF

# Positive control: the same HOME does break an unisolated git.
if "$REAL_GIT" ls-remote "$ORIGIN" >"$OUT" 2>&1; then
  fail "positive control: the insteadOf rewrite must break a plain git ls-remote"
else
  pass "positive control: the insteadOf rewrite breaks a plain git ls-remote"
fi

HOSTILE="$WORK/share-hostile"
if deploy "$PIN_B" "$HOSTILE" && check "$PIN_B" "$HOSTILE" && [ "$(cat "$HOSTILE/DEPLOYED_MANIFEST")" = "$(cat "$SHARE/DEPLOYED_MANIFEST")" ] &&
  grep -q 'REDACT = "a"' "$HOSTILE/ccs/session_redact.py"; then
  pass "a global insteadOf and filter have no effect"
else
  fail "a global insteadOf and filter have no effect"
fi
rm -f "$HOME/.gitconfig" "$HOME/attributes"

# --- check-pin.sh --------------------------------------------------------------

pin_case() { # <description> <want status: pass|fail> <expected text> <pin file body>
  printf '%b' "$4" >"$WORK/test.pin"
  SESSION_SEARCH_ORIGIN="$ORIGIN" bash "$CHECK_PIN" "$WORK/test.pin" >"$OUT" 2>&1
  local rc=$?
  if { [ "$2" = pass ] && [ "$rc" -eq 0 ]; } || { [ "$2" = fail ] && [ "$rc" -ne 0 ]; }; then
    if grep -q "$3" "$OUT"; then
      pass "check-pin: $1"
      return
    fi
  fi
  fail "check-pin: $1 (rc=$rc)"
}

pin_case "a pin on main passes" pass "is on main" "$PIN_A\n"
pin_case "an unmerged branch pin fails" fail "not an ancestor" "$PIN_SIDE\n"
pin_case "a short SHA fails" fail "not a 40-hex" "${PIN_A%?}\n"
pin_case "two lines fail" fail "exactly one line" "$PIN_A\n$PIN_B\n"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "OK: all deploy-pinned cases passed"
else
  echo "FAILED: see above"
  exit 1
fi
