#!/usr/bin/env bash

# Black-box tests for hooks/format-on-edit.rb (PostToolUse, Edit|Write). Each
# case writes a file in a scratch dir, pipes an Edit payload to the hook the way
# ruby-shim runs it (ruby -E UTF-8), and asserts the exit
# code, the file content afterwards and whether the hook reported a change.
# Fixing cases and leave-alone cases are paired, so neither a no-op hook nor a
# hook that rewrites everything passes. rustfmt / terraform cases run only when
# the tool is installed and say SKIP otherwise. The wiring cases fail when the
# settings.json registration or the default.rb distribution is removed, or when
# the retired check-* hooks are registered again.
#
# Usage: test-format-on-edit.sh <path/to/format-on-edit.rb>

set -u

HOOK=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
HOOKS_DIR=$(dirname "$HOOK")
SETTINGS="$HOOKS_DIR/../settings.json"
DEFAULT_RB="$HOOKS_DIR/../../default.rb"

# Resolve ruby before anything else: a mise shim needs the real HOME's trust
# store, so only the no-tool case below runs under a throwaway HOME.
RUBY_BIN=$(ruby -e 'print RbConfig.ruby')
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
ng() { fail=$((fail + 1)); echo "FAIL $1"; }

# run_hook <file> → sets RC, OUT
run_hook() {
  OUT=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1" | "$RUBY_BIN" -E UTF-8 "$HOOK" 2>"$SCRATCH/stderr")
  RC=$?
}

expect_file() { # name file expected-bytes(printf format)
  local want
  want=$(printf "$3" | od -An -c)
  if [ "$(od -An -c <"$2")" = "$want" ]; then ok "$1"; else ng "$1 (got: $(od -An -c <"$2" | tr -s ' '))"; fi
}

expect_reported() { # name substring
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "$2"; then ok "$1"; else ng "$1 (rc=$RC out=$OUT)"; fi
}

expect_silent() { # name
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "$1"; else ng "$1 (rc=$RC out=$OUT)"; fi
}

D="$SCRATCH/work"
mkdir -p "$D"

# whitespace-only lines are emptied; lines with text keep their spaces
printf 'a\n   \nb  \n\t\nc\n' >"$D/ws.txt"
run_hook "$D/ws.txt"
expect_file "whitespace-only lines emptied" "$D/ws.txt" 'a\n\nb  \n\nc\n'
expect_reported "whitespace fix reported" "emptied 2 whitespace-only line"

# missing final newline is added
printf 'x\ny' >"$D/nl.txt"
run_hook "$D/nl.txt"
expect_file "final newline added" "$D/nl.txt" 'x\ny\n'
expect_reported "newline fix reported" "added the final newline"

# CRLF file keeps CRLF
printf 'a\r\n  \r\nb' >"$D/crlf.txt"
run_hook "$D/crlf.txt"
expect_file "CRLF kept" "$D/crlf.txt" 'a\r\n\r\nb\r\n'

# clean file is untouched and nothing is reported
printf 'clean\n\nfile\n' >"$D/clean.txt"
before=$(stat -c %Y "$D/clean.txt" 2>/dev/null || stat -f %m "$D/clean.txt")
sleep 1
run_hook "$D/clean.txt"
expect_file "clean file unchanged" "$D/clean.txt" 'clean\n\nfile\n'
expect_silent "clean file silent"
after=$(stat -c %Y "$D/clean.txt" 2>/dev/null || stat -f %m "$D/clean.txt")
if [ "$before" = "$after" ]; then ok "clean file not rewritten"; else ng "clean file rewritten (mtime changed)"; fi

# binary extension and NUL content are skipped
printf 'img  \n  ' >"$D/pic.png"
run_hook "$D/pic.png"
expect_file "binary extension skipped" "$D/pic.png" 'img  \n  '
expect_silent "binary extension silent"
printf 'a\0b\n   \nc' >"$D/nul.dat"
run_hook "$D/nul.dat"
expect_file "NUL content skipped" "$D/nul.dat" 'a\0b\n   \nc'

# missing path, missing file and malformed payload all exit 0 silently
OUT=$(printf '{"tool_input":{}}' | "$RUBY_BIN" -E UTF-8 "$HOOK" 2>/dev/null); RC=$?
expect_silent "no file_path"
run_hook "$D/does-not-exist.rs"
expect_silent "missing file"
OUT=$(printf 'not json' | "$RUBY_BIN" -E UTF-8 "$HOOK" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ]; then ok "malformed payload exits 0"; else ng "malformed payload rc=$RC"; fi

# rustfmt inside a crate; a .rs file outside any crate is left alone
if command -v cargo >/dev/null 2>&1 && command -v rustfmt >/dev/null 2>&1; then
  ( cd "$SCRATCH" && cargo new -q --vcs none fmtprobe >/dev/null 2>&1 )
  printf 'fn main(){let x=1;println!("{}",x);}\n' >"$SCRATCH/fmtprobe/src/main.rs"
  run_hook "$SCRATCH/fmtprobe/src/main.rs"
  if grep -q '    let x = 1;' "$SCRATCH/fmtprobe/src/main.rs"; then ok "rustfmt formats a crate file"; else ng "rustfmt did not format: $(cat "$SCRATCH/fmtprobe/src/main.rs")"; fi
  expect_reported "rustfmt reported" "formatted with rustfmt"
  printf 'fn main(){let x=1;}\n' >"$D/loose.rs"
  run_hook "$D/loose.rs"
  expect_file "rs outside a crate left alone" "$D/loose.rs" 'fn main(){let x=1;}\n'
else
  echo "SKIP rustfmt cases (cargo/rustfmt not installed)"
fi

# terraform fmt
if command -v terraform >/dev/null 2>&1; then
  printf 'resource "null_resource" "a" {\ntriggers={a="b"}\n}\n' >"$D/main.tf"
  run_hook "$D/main.tf"
  if grep -q '  triggers = { a = "b" }' "$D/main.tf"; then ok "terraform fmt formats .tf"; else ng "terraform fmt did not format: $(cat "$D/main.tf")"; fi
  expect_reported "terraform fmt reported" "formatted with terraform fmt"
else
  echo "SKIP terraform case (terraform not installed)"
fi

# a formatter that cannot run (no tools on PATH) still exits 0 and tidies
printf 'fn main(){}\n  \n' >"$D/notool.rs"
mkdir -p "$SCRATCH/home"
OUT=$(printf '{"tool_input":{"file_path":"%s"}}' "$D/notool.rs" | HOME="$SCRATCH/home" PATH=/nonexistent "$RUBY_BIN" -E UTF-8 "$HOOK" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ]; then ok "no formatter on PATH exits 0"; else ng "no formatter rc=$RC"; fi

# wiring
if grep -q 'hooks/format-on-edit.rb' "$SETTINGS"; then ok "settings.json registers format-on-edit"; else ng "settings.json lacks format-on-edit"; fi
if grep -qE 'check-trailing-newline|check-whitespace-lines' "$SETTINGS"; then ng "settings.json still registers a retired check-* hook"; else ok "retired check-* hooks unregistered"; fi
if grep -qE '%w\(.*format-on-edit\.rb' "$DEFAULT_RB"; then ok "default.rb distributes format-on-edit"; else ng "default.rb lacks format-on-edit"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
