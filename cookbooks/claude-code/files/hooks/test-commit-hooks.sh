#!/usr/bin/env bash

# Black-box tests for the two git-commit PreToolUse hooks and the parser they
# share: hooks/block-co-authored-by.rb, hooks/pre-commit-test.rb and
# hooks/git-command.rb (SH1-79). Every case pipes a Bash tool payload to the
# hook the way ruby-shim runs it (ruby -E UTF-8) under a throwaway HOME, from a
# scratch cwd, and asserts the exit code plus stderr.
#
# block-co-authored-by: each message source is run as a PAIR — once with a
# Co-Authored-By trailer (must exit 2 with the hook's message) and once with a
# clean Reviewed-by line (must exit 0, silent) — so neither an always-block nor
# a no-op hook passes. Sources include commits behind wrappers the parser does
# not list (xargs, mise exec --, flock, find -exec), values held in variables
# the command sets, -F /dev/stdin and $(cat file), message paths through
# $HOME / $TMPDIR / $PWD / $(pwd) / $CLAUDE_PROJECT_DIR / ${NAME:-default}
# (the hook runs with HOME, TMPDIR and CLAUDE_PROJECT_DIR set to scratch
# dirs), a $(mktemp) message file, -F <(...) / --file=<(...) / < <(...), and
# { ...; } / ( ... ) group output piped or redirected into the message. Then
# allow-only cases: the trailer outside any git commit (echo, git log --grep,
# grep -r, a comment, hg commit, a doc heredoc next to `done < <(ls)`, a group
# member piped or redirected elsewhere, ...), and 5000-deep nesting, which
# must exit 0 rather than crash.
#
# pre-commit-test: a fake `make` on PATH logs every call. A repo whose
# `make test` fails must block a commit addressed to it from ANOTHER cwd
# (git -C, the add/commit chain, cd, bash -c, a wrapper, -C "$R", --work-tree,
# cd / -C "$(git rev-parse --show-toplevel)" from a subdirectory of a real
# git repo); a passing repo exits 0 after running its tests; a command with no
# commit (or a --git-dir-only / remote commit) exits 0 without calling make.
#
# The last section reruns key cases with filter_map / tally removed, the way
# CRuby 2.6 lacks them.
#
# Usage: bash test-commit-hooks.sh [<hooks-dir>]   (default: this script's dir)

set -uo pipefail
case "${1:-}" in
  "") HOOKS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) ;;
  /*) HOOKS="$1" ;;
  *) HOOKS="$PWD/$1" ;;
esac
BLOCK="$HOOKS/block-co-authored-by.rb"
PRECOMMIT="$HOOKS/pre-commit-test.rb"
# Resolve the real interpreter once: a version-manager shim (rbenv / mise) on
# PATH can fail once HOME points at a throwaway directory.
RUBY="${RUBY:-$(ruby -e 'print RbConfig.ruby')}"
REAL_MAKE=$(command -v make) || { echo "FAIL precondition: make not found"; exit 1; }
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
pass=0; fail=0

mkdir -p "$D/home" "$D/work" "$D/repo" "$D/bin" "$D/failrepo" "$D/passrepo" "$D/tmp" \
  "$D/gitrepo/sub" "$D/gitfail/sub" "$D/passrepo/sub"

BAD_T='Co-Authored-By: Claude <noreply@anthropic.com>'
OK_T='Reviewed-by: Alice <alice@example.com>'
# msg-bad.txt / msg-ok.txt in the -C repo, in $HOME and $TMPDIR (both set for
# the hook below), and at the top of a real git repo (rev-parse cases).
for dir in repo home tmp gitrepo; do
  printf 'fix: thing\n\n%s\n' "$BAD_T" > "$D/$dir/msg-bad.txt"
  printf 'fix: thing\n\n%s\n' "$OK_T" > "$D/$dir/msg-ok.txt"
done
# A trailer-bearing file in the CWD only: a commit addressed to $D/repo with
# -F msg-cwd.txt must not read it.
printf 'fix: thing\n\n%s\n' "$BAD_T" > "$D/work/msg-cwd.txt"

printf 'test:\n\t@echo FAILING-SUITE-MARKER; exit 1\n' > "$D/failrepo/Makefile"
printf 'test:\n\t@echo passing-suite\n' > "$D/passrepo/Makefile"
printf 'test:\n\t@echo FAILING-SUITE-MARKER; exit 1\n' > "$D/gitfail/Makefile"
git init -q "$D/gitrepo" && git init -q "$D/gitfail" || { echo "FAIL precondition: git init"; exit 1; }
cat > "$D/bin/make" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$PWD" "\$*" >> "$D/make.log"
exec "$REAL_MAKE" "\$@"
EOF
chmod +x "$D/bin/make"

ok() { pass=$((pass+1)); printf 'ok   %-58s %s\n' "$1" "$2"; }
bad() { fail=$((fail+1)); printf 'FAIL %-58s %s\n' "$1" "$2"; }

# fill <template>: @D@ -> scratch root
fill() { local s="$1"; printf '%s' "${s//@D@/$D}"; }

# Extra interpreter flags for hook runs: the Ruby 2.6 section sets a preload
# that removes the 2.7+ methods.
PRELOAD=()

# hook <script> <command> <cwd>: sets rc and err (stderr; stdout must be empty).
# The hook gets the environment the Bash tool would expand $HOME, $TMPDIR and
# $CLAUDE_PROJECT_DIR from.
hook() {
  local json out
  json=$("$RUBY" -rjson -e 'print JSON.generate("session_id" => "t", "tool_name" => "Bash",
    "tool_input" => { "command" => ARGV[0] }, "cwd" => ARGV[1])' "$2" "$3")
  out=$(cd "$3" && printf '%s' "$json" | HOME="$D/home" TMPDIR="$D/tmp" CLAUDE_PROJECT_DIR="$D/repo" \
    PATH="$D/bin:$PATH" "$RUBY" -E UTF-8 ${PRELOAD[@]+"${PRELOAD[@]}"} "$1" 2>"$D/stderr")
  rc=$?
  err=$(cat "$D/stderr")
  [ -z "$out" ] || err="unexpected stdout: $out | $err"
}

expect_block() { # expect_block <name> <command-template> [cwd]
  hook "$BLOCK" "$(fill "$2")" "${3:-$D/work}"
  if [ "$rc" -eq 2 ] && [[ "$err" == *"ERROR: Do not include Co-Authored-By in git commits"* ]]; then
    ok "$1" "BLOCK"
  else
    bad "$1" "want=BLOCK got rc=$rc :: $err"
  fi
}

expect_allow() { # expect_allow <name> <command-template> [cwd]
  hook "$BLOCK" "$(fill "$2")" "${3:-$D/work}"
  if [ "$rc" -eq 0 ] && [ -z "$err" ]; then
    ok "$1" "ALLOW"
  else
    bad "$1" "want=ALLOW got rc=$rc :: $err"
  fi
}

# pair <name> <template> [cwd]: @T@ -> trailer / clean line, @F@ -> the
# msg-bad.txt / msg-ok.txt file in $D/repo. Trailer must block, clean must not.
pair() {
  local t="$2" b g
  b="${t//@T@/$BAD_T}"; b="${b//@F@/msg-bad.txt}"
  g="${t//@T@/$OK_T}"; g="${g//@F@/msg-ok.txt}"
  expect_block "$1" "$b" "${3:-}"
  expect_allow "$1 [clean]" "$g" "${3:-}"
}

echo "== block-co-authored-by: message sources (trailer blocks, clean allows)"
pair "plain -m" 'git commit -m "fix: thing" -m "@T@"'
pair "attached -m\"...\"" 'git commit -m"@T@"'
pair "git -C /abs commit -m" 'git -C @D@/repo commit -m "fix" -m "@T@"'
pair "chain: test -d && git -C add && git -C commit -F rel" \
  'test -d @D@/repo && git -C @D@/repo add -A && git -C @D@/repo commit -F @F@'
pair "git -c k=v commit" 'git -c user.name=x commit -m "@T@"'
pair "global opts --no-pager -P --git-dir=" \
  'git --no-pager -P --git-dir=@D@/repo/.git --work-tree=@D@/repo commit -m "@T@"'
pair "env VAR=1 git commit" 'env GIT_AUTHOR_NAME=x git commit -m "@T@"'
pair "VAR=1 git commit (assignment prefix)" 'GIT_EDITOR=true git commit -m "@T@"'
pair "command git commit" 'command git commit -m "@T@"'
pair "timeout + nice wrappers" 'timeout 30 nice -n 5 git commit -m "@T@"'
pair "/usr/bin/git path" '/usr/bin/git commit -m "@T@"'
pair "bash -c 'git commit -m \"...\"'" "bash -c 'git commit -m \"@T@\"'"
pair "sh -c \"cd repo && git commit -F rel\"" 'sh -c "cd @D@/repo && git commit -F @F@"'
pair "(cd repo && git commit -F rel) subshell" '(cd @D@/repo && git commit -F @F@)'
pair "--message=\"...\"" 'git commit --message="@T@"'
pair "--message \"...\" (separate)" 'git commit --message "@T@"'
pair "--mess abbreviation" 'git commit --mess "@T@"'
pair "--trailer \"...\"" 'git commit -m fix --trailer "@T@"'
pair "--trailer=\"...\"" 'git commit -m fix --trailer="@T@"'
pair "-am \"...\" cluster" "git commit -am \"fix: thing

@T@\""
pair "ANSI-C \$'...'" "git commit -m \$'fix: thing\\n\\n@T@'"
pair "-F - <<'EOF' heredoc (balanced quotes)" "git commit -F - <<'EOF'
fix: \"quoted\" thing

@T@
EOF"
pair "-F - <<'EOF' heredoc with an apostrophe" "git commit -F - <<'EOF'
fix: don't break (things

@T@
EOF"
pair "-F - <<-EOF heredoc, tab-stripped" "git commit -F - <<-EOF
	fix: thing

	@T@
	EOF"
pair "-m \"\$(cat <<'EOF' ... EOF)\"" "git commit -m \"\$(cat <<'EOF'
fix: \"quoted\" (paren, don't

@T@
EOF
)\""
pair "--file=- <<< here-string" 'git commit --file=- <<< "@T@"'
pair "echo ... | git commit -F -" 'echo "@T@" | git commit -F -'
pair "printf ... | git commit -F -" "printf '%s\\n' 'fix: thing' '@T@' | git commit -F -"
pair "cat file | git commit -F -" 'cat @D@/repo/@F@ | git commit -F -'
pair "cd repo && git commit -F - < rel" 'cd @D@/repo && git commit -F - < @F@'
pair "cd repo && git commit -F rel" 'cd @D@/repo && git commit -F @F@'
pair "git -C repo commit --file=rel" 'git -C @D@/repo commit --file=@F@'
pair "git -C repo commit -t template" 'git -C @D@/repo commit -t @F@'
pair "cat > new <<EOF, then -F new (not yet on disk)" "cat > @D@/work/new-msg.txt <<'EOF'
fix: thing

@T@
EOF
git add -A && git commit -F new-msg.txt"
expect_block "lowercase co-authored-by" 'git commit -m "fix" -m "co-authored-by: someone <s@example.com>"'
expect_block "unparseable (unterminated quote) with trailer" "git commit -m \"fix: $BAD_T"
expect_allow "unparseable (unterminated quote), clean" 'git commit -m "fix: thing'
expect_block "unparseable bash -c body inside a valid chain" \
  "cd @D@/repo && bash -c \"git commit -m 'fix: $BAD_T\" && git status"

echo "== block-co-authored-by: commit behind a wrapper the parser does not list"
pair "mise exec -- git commit" 'mise exec -- git commit -m fix -m "@T@"'
pair "xargs git commit -m" 'xargs git commit -m "@T@" < /dev/null'
pair "flock f git commit" 'flock @D@/work/lock git commit -m "@T@"'
pair "find . -exec git commit ... \\;" 'find . -maxdepth 0 -exec git commit -m "@T@" \;'
pair "stdbuf -oL git -C repo commit -F rel" 'stdbuf -oL git -C @D@/repo commit -F @F@'
pair "ssh host git commit -m (remote: message still checked)" 'ssh host git commit -m "@T@"'
expect_allow "echo git commit -m trailer (data command, unquoted)" "echo git commit -m '$BAD_T'"
expect_allow "which git; grep -r git commit trailer" "which git && grep -r git commit '$BAD_T' ."

echo "== block-co-authored-by: message held in a variable the command sets"
pair "MSG=...; git commit -m \"\$MSG\"" 'MSG="fix: thing

@T@"; git commit -m "$MSG"'
pair "TR=...; --trailer \"\$TR\"" 'TR="@T@"; git commit -m fix --trailer "$TR"'
pair "read -r -d '' MSG <<'EOF'; -m \"\$MSG\"" "read -r -d '' MSG <<'EOF'
fix: thing

@T@
EOF
git commit -m \"\$MSG\""
pair "F=path; printf > \"\$F\"; -F \"\$F\"" \
  "F=@D@/work/var-msg.txt; printf 'fix\\n\\n%s\\n' '@T@' > \"\$F\"; git commit -F \"\$F\""
pair "R=repo; git -C \"\$R\" commit -F rel" 'R=@D@/repo; git -C "$R" commit -F @F@'
pair "export MSG=...; -m \"\${MSG}\"" 'export MSG="@T@" && git commit -m "${MSG}"'
pair "printf -v MSG; -m \"\$MSG\"" "printf -v MSG 'fix\\n\\n%s' '@T@'; git commit -m \"\$MSG\""
pair "for M in ...; do git commit -m \"\$M\"" 'for M in "@T@"; do git commit -m "$M"; done'
expect_block "unmodeled assignment (mapfile) of the trailer, then \$MSG" "mapfile -t MSG <<'EOF'
$BAD_T
EOF
git commit -m \"\$MSG\""
expect_allow "single-quoted '\$MSG' stays literal" "MSG='$BAD_T'; git commit -m '\$MSG'"
expect_allow "assignment inside ( ) does not leak" "(MSG='$BAD_T'; echo \"\$MSG\"); git commit -m \"\$MSG\""

echo "== block-co-authored-by: -F /dev/stdin and \$(cat file)"
pair "-F /dev/stdin <<'EOF'" "git commit -F /dev/stdin <<'EOF'
fix: thing

@T@
EOF"
pair "echo ... | git commit --file=/dev/stdin" 'echo "@T@" | git commit --file=/dev/stdin'
pair "-F /dev/fd/0 <<< here-string" 'git commit -F /dev/fd/0 <<< "@T@"'
pair "cd repo && git commit -m \"\$(cat rel)\"" 'cd @D@/repo && git commit -m "$(cat @F@)"'
pair "git commit -m \"\$(< abs)\"" 'git commit -m "$(< @D@/repo/@F@)"'
pair "printf > file && -m \"\$(cat file)\" (written first)" \
  "printf 'fix\\n\\n%s\\n' '@T@' > @D@/work/sub-msg.txt && git commit -m \"\$(cat @D@/work/sub-msg.txt)\""
pair "MSG=\$(cat file); -m \"\$MSG\"" 'MSG=$(cat @D@/repo/@F@); git commit -m "$MSG"'
expect_block "\$(cat rel) reads the shell cwd, not the -C dir" \
  'git -C @D@/repo commit -m "$(cat msg-cwd.txt)"'

echo "== block-co-authored-by: message path through \$HOME / \$TMPDIR / \$PWD / env"
pair "cat > \"\$HOME/f\" <<EOF, then -F \"\$HOME/f\"" "cat > \"\$HOME/commit-msg.txt\" <<'EOF'
fix: thing

@T@
EOF
git commit -F \"\$HOME/commit-msg.txt\""
pair "cat > \"\$TMPDIR/f\" <<EOF, then -F \"\$TMPDIR/f\"" "cat > \"\$TMPDIR/commit-msg.txt\" <<'EOF'
fix: thing

@T@
EOF
git commit -F \"\$TMPDIR/commit-msg.txt\""
pair "-F \"\$HOME/f\" on disk" 'git commit -F "$HOME/@F@"'
pair "-F \${HOME}/f on disk" 'git commit -F ${HOME}/@F@'
pair "F=\"\$HOME/f\"; -F \"\$F\"" 'F="$HOME/@F@"; git commit -F "$F"'
pair "-F \"\${TMPDIR:-/tmp}/f\"" 'git commit -F "${TMPDIR:-/tmp}/@F@"'
pair "MSG=\"\${TMPDIR}/m\"; cat > \"\$MSG\"; -F \"\$MSG\"" "MSG=\"\${TMPDIR}/m.txt\"
cat > \"\$MSG\" <<'EOF'
fix: thing

@T@
EOF
git commit -F \"\$MSG\""
pair "cd repo && -F \"\$PWD/f\"" 'cd @D@/repo && git commit -F "$PWD/@F@"'
pair "cd repo && -F \"\$(pwd)/f\"" 'cd @D@/repo && git commit -F "$(pwd)/@F@"'
pair "-F \"\$CLAUDE_PROJECT_DIR/f\"" 'git commit -F "$CLAUDE_PROJECT_DIR/@F@"'
pair "git -C repo commit -F \"\$HOME/f\"" 'git -C @D@/repo commit -F "$HOME/@F@"'
pair "-F - < \"\$TMPDIR/f\"" 'git commit -F - < "$TMPDIR/@F@"'
pair "-m \"\$(cat \"\$TMPDIR/f\")\"" 'git commit -m "$(cat "$TMPDIR/@F@")"'
pair "cd \"\$(git rev-parse --show-toplevel)\" && -F rel (from sub/)" \
  'cd "$(git rev-parse --show-toplevel)" && git commit -F @F@' "$D/gitrepo/sub"
expect_allow "\${UNSET:-default} names the default, not the trailer file" \
  'git commit -F "${UNSET_COMMIT_HOOK_TEST_VAR:-@D@/repo}/msg-ok.txt"'

echo "== block-co-authored-by: message file named by \$(mktemp)"
pair "F=\$(mktemp) + cat > \"\$F\" <<EOF + -F \"\$F\"" "MSG_FILE=\$(mktemp) && cat > \"\$MSG_FILE\" <<'EOF'
fix: thing

@T@
EOF
git commit -F \"\$MSG_FILE\" && rm -f \"\$MSG_FILE\""
pair "f=\$(mktemp) + printf > \"\$f\" + --file=\"\$f\"" \
  "f=\$(mktemp); printf '%s\\n' 'fix' '' '@T@' > \"\$f\"; git commit --file=\"\$f\""
pair "D=\$(mktemp -d) + cat > \"\$D/msg\" + -F \"\$D/msg\"" "D=\$(mktemp -d)
cat > \"\$D/msg\" <<'EOF'
fix: thing

@T@
EOF
git commit -F \"\$D/msg\""
pair "F=\$(mktemp) + cat > + -m \"\$(cat \"\$F\")\"" "F=\$(mktemp)
cat > \"\$F\" <<'EOF'
fix: thing

@T@
EOF
git commit -m \"\$(cat \"\$F\")\""
pair "F=\$(mktemp) + tee \"\$F\" <<EOF + git -C repo commit -F" "F=\$(mktemp); trap 'rm -f \"\$F\"' EXIT
tee \"\$F\" >/dev/null <<'EOF'
fix: thing

@T@
EOF
git -C @D@/repo commit -F \"\$F\""

echo "== block-co-authored-by: process substitution as the message"
pair "-F <(printf ...)" "git commit -F <(printf 'fix: thing\\n\\n@T@\\n')"
pair "-F<(printf ...) attached" "git commit -F<(printf 'fix: thing\\n\\n@T@\\n')"
pair "--file=<(echo ...)" "git commit --file=<(echo '@T@')"
pair "-F <(echo; echo; echo) list" "git commit -F <(echo fix; echo; echo '@T@')"
pair "-F <(cat <<'EOF' ... EOF)" "git commit -F <(cat <<'EOF'
fix: thing

@T@
EOF
)"
pair "-F - < <(printf ...)" "git commit -F - < <(printf 'fix: thing\\n\\n%s\\n' '@T@')"
pair "-t <(cat rel) in the shell cwd" 'cd @D@/repo && git commit -t <(cat @F@)'

echo "== block-co-authored-by: brace group / subshell output as the message"
pair "{ echo; echo; } | git commit -F -" "{ echo 'fix: thing'; echo; echo '@T@'; } | git commit -F -"
pair "( echo; echo ) | git commit -F -" "( echo 'fix: thing'; echo; echo '@T@' ) | git commit -F -"
pair "{ echo; } > file && git commit -F file" \
  "{ echo 'fix: thing'; echo; echo '@T@'; } > .git-msg.txt && git commit -F .git-msg.txt"
pair "( echo ) > file && git commit -F file" "( echo 'fix: thing'; echo '@T@' ) > m6.txt && git commit -F m6.txt"
pair "multi-line { ... } > file, then -F file" "{
  echo 'fix: thing'
  echo
  echo '@T@'
} > m5.txt
git commit -F m5.txt"
pair "{ printf; printf; } | --file=/dev/stdin" \
  "{ printf 'fix\\n\\n'; printf '%s\\n' '@T@'; } | git commit --file=/dev/stdin"
pair "{ ( echo ); echo; } nested | -F -" "{ ( echo '@T@' ); echo fix; } | git commit -F -"
expect_allow "group member piped elsewhere does not reach the commit" \
  "{ echo '$BAD_T' | grep -v Co-Authored-By; echo fix; } | git commit -F -"
expect_allow "group member redirected to stderr does not reach the commit" \
  "( echo '$BAD_T' >&2; echo fix ) | git commit -F -"
expect_allow "group writing the trailer to a file the commit does not read" \
  "{ echo '$BAD_T'; } > @D@/work/notes.txt && git commit -m fix"

echo "== block-co-authored-by: process substitution, fallback, deep nesting"
expect_block "git commit -m trailer 2> >(tee e)" "git commit -m '$BAD_T' 2> >(tee @D@/work/e.log)"
expect_allow "doc heredoc naming the trailer + done < <(ls)" "cat > @D@/work/doc.md <<'EOF'
Never run git commit with a $BAD_T trailer.
EOF
while read -r f; do wc -l \"\$f\"; done < <(ls)"
expect_allow "unparseable: trailer in a later command segment" \
  "git commit -m fix && git log --grep='$BAD_T' && echo \"oops"
DEEP_OPEN=$(printf 'echo "$(%.0s' $(seq 5000)); DEEP_CLOSE=$(printf ')"%.0s' $(seq 5000))
expect_allow "5000-deep \"\$( nesting exits 0 (no SystemStackError)" "${DEEP_OPEN}git commit -m x${DEEP_CLOSE}"
expect_allow "5000-deep unterminated nesting exits 0" "${DEEP_OPEN}git commit -m x"
expect_block "5000-deep nesting with the trailer still blocks" "${DEEP_OPEN}git commit -m '$BAD_T'${DEEP_CLOSE}"

echo "== block-co-authored-by: trailer outside any git commit"
expect_allow "echo \"git commit Co-Authored-By\"" 'echo "git commit Co-Authored-By"'
expect_allow "git log --grep Co-Authored-By" 'git log --grep Co-Authored-By'
expect_allow "git commit && git log --grep=Co-Authored-By" 'git commit -m fix && git log --grep="Co-Authored-By"'
expect_allow "grep -r Co-Authored-By ." 'grep -r Co-Authored-By .'
expect_allow "git commit --amend --no-edit" 'git commit --amend --no-edit'
expect_allow "hg commit (non-git) with trailer" 'hg commit -m "Co-Authored-By: X <x@example.com>"'
expect_allow "comment after git commit" 'git commit -m fix # Co-Authored-By: X'
expect_allow "trailer written to an unrelated file" \
  "printf 'Co-Authored-By: X\\n' > @D@/work/notes.txt && git commit -m fix"
expect_allow "-F rel resolves in the -C dir, not cwd" 'git -C @D@/repo commit -F msg-cwd.txt'
expect_allow "command -v git (lookup only)" 'command -v git && echo commit'
hook "$BLOCK" "" "$D/work"
[ "$rc" -eq 0 ] && [ -z "$err" ] && ok "empty command" "ALLOW" || bad "empty command" "rc=$rc :: $err"
out=$(printf 'not-json' | HOME="$D/home" "$RUBY" -E UTF-8 "$BLOCK" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "malformed payload (block hook)" "ALLOW" \
  || bad "malformed payload (block hook)" "rc=$rc :: $out"

echo "== pre-commit-test: tests run in each commit's effective directory"
precommit() { # precommit <name> <want-rc> <command-template> <cwd> [stderr-substring] [make-log-substring|NOMAKE]
  : > "$D/make.log"
  hook "$PRECOMMIT" "$(fill "$3")" "$4"
  local why=""
  [ "$rc" -eq "$2" ] || why="want rc=$2 got rc=$rc"
  if [ -n "${5:-}" ] && [[ "$err" != *"$(fill "$5")"* ]]; then why="$why; stderr lacks '$(fill "$5")'"; fi
  if [ "$2" -eq 0 ] && [ -z "${5:-}" ] && [ -n "$err" ]; then why="$why; unexpected stderr"; fi
  case "${6:-}" in
    "") ;;
    NOMAKE) [ -s "$D/make.log" ] && why="$why; make was called: $(tr '\n' ' ' < "$D/make.log")" ;;
    *) grep -qF -- "$(fill "$6")" "$D/make.log" || why="$why; make log lacks '$(fill "$6")'" ;;
  esac
  if [ -z "$why" ]; then ok "$1" "rc=$rc"; else bad "$1" "$why :: $err"; fi
}
precommit "git -C failrepo commit from another cwd" 2 \
  'git -C @D@/failrepo commit -m x' "$D/work" "FAILING-SUITE-MARKER" "@D@/failrepo|test"
precommit "  ... names the command and dir" 2 \
  'git -C @D@/failrepo commit -m x' "$D/work" 'pre-commit-test: `make test` failed in @D@/failrepo'
precommit "chain: test -d && git -C add && git -C commit -F" 2 \
  'test -d @D@/failrepo && git -C @D@/failrepo add -A && git -C @D@/failrepo commit -F msg.txt' \
  "$D/work" "FAILING-SUITE-MARKER"
precommit "cd failrepo && git commit" 2 'cd @D@/failrepo && git commit -m x' "$D/work" "FAILING-SUITE-MARKER"
precommit "bash -c 'git -C failrepo commit'" 2 "bash -c 'git -C @D@/failrepo commit -m x'" "$D/work" "FAILING-SUITE-MARKER"
precommit "plain git commit in failing cwd" 2 'git commit -m x' "$D/failrepo" "FAILING-SUITE-MARKER"
precommit "passing repo via git -C exits 0 after testing" 0 \
  'git -C @D@/passrepo commit -m x' "$D/work" "" "@D@/passrepo|test"
precommit "passing then failing repo: both tested, blocks" 2 \
  'git -C @D@/passrepo commit -m a && git -C @D@/failrepo commit -m b' "$D/work" "FAILING-SUITE-MARKER" "@D@/passrepo|test"
precommit "no commit (git status) runs no make" 0 'git -C @D@/failrepo status' "$D/failrepo" "" NOMAKE
precommit "echo \"git commit\" runs no make" 0 'echo "git commit -m x"' "$D/failrepo" "" NOMAKE
precommit "git -C \"\$VAR\" commit (unknown dir) is skipped" 0 'git -C "$REPO" commit -m x' "$D/failrepo" "" NOMAKE
precommit "cwd without a project exits 0" 0 'git commit -m x' "$D/work" "" NOMAKE
precommit "mise exec -- git -C failrepo commit" 2 'mise exec -- git -C @D@/failrepo commit -m x' "$D/work" "FAILING-SUITE-MARKER"
precommit "xargs git commit in failing cwd" 2 'xargs git commit -m x < /dev/null' "$D/failrepo" "FAILING-SUITE-MARKER"
precommit "ssh host git -C <dir> commit (remote) runs no make" 0 'ssh host git -C @D@/failrepo commit -m x' "$D/work" "" NOMAKE
precommit "R=failrepo; git -C \"\$R\" add && commit" 2 \
  'R=@D@/failrepo; git -C "$R" add -A && git -C "$R" commit -m x' "$D/work" "FAILING-SUITE-MARKER"
precommit "doc heredoc + done < <(ls) runs no make" 0 "cat > @D@/work/doc.md <<'EOF'
Run git commit only after tests pass.
EOF
while read -r f; do wc -l \"\$f\"; done < <(ls)" "$D/failrepo" "" NOMAKE
precommit "echo \"git commit\" > >(tee f) runs no make" 0 'echo "tip: git commit -m x" > >(tee @D@/work/n.txt)' "$D/failrepo" "" NOMAKE
precommit "git commit -m x > >(tee log) is a commit" 2 'git commit -m x > >(tee @D@/work/c.log)' "$D/failrepo" "FAILING-SUITE-MARKER"
precommit "fallback: -c commit.gpgsign=false log is not a commit" 0 \
  'git -c commit.gpgsign=false log -1; echo "oops' "$D/failrepo" "" NOMAKE
precommit "fallback: git commit inside a heredoc body is not a commit" 0 "cat > @D@/work/d.md <<'EOF'
Run git commit -m x only after tests pass.
EOF
echo \"oops" "$D/failrepo" "" NOMAKE
precommit "--work-tree=passrepo from a failing cwd tests passrepo" 0 \
  'git --git-dir=@D@/passrepo/.git --work-tree=@D@/passrepo commit -m x' "$D/failrepo" "" "@D@/passrepo|test"
precommit "GIT_DIR= GIT_WORK_TREE=passrepo from a failing cwd" 0 \
  'GIT_DIR=@D@/passrepo/.git GIT_WORK_TREE=@D@/passrepo git commit -m x' "$D/failrepo" "" "@D@/passrepo|test"
precommit "--work-tree=failrepo from another cwd blocks" 2 \
  'git --git-dir=@D@/failrepo/.git --work-tree=@D@/failrepo commit -m x' "$D/work" "FAILING-SUITE-MARKER"
precommit "--git-dir without a work tree is skipped" 0 'git --git-dir=@D@/passrepo/.git commit -m x' "$D/failrepo" "" NOMAKE
precommit "export GIT_DIR; git commit is skipped" 0 'export GIT_DIR=@D@/passrepo/.git; git commit -m x' "$D/failrepo" "" NOMAKE
precommit "5000-deep nesting exits 0 (no SystemStackError)" 0 "${DEEP_OPEN}git commit -m x${DEEP_CLOSE}" "$D/work" "" NOMAKE
precommit "cd \"\$(git rev-parse --show-toplevel)\" from sub/" 2 \
  'cd "$(git rev-parse --show-toplevel)" && git add -A && git commit -m x' "$D/gitfail/sub" \
  "FAILING-SUITE-MARKER" "@D@/gitfail|test"
precommit "git -C \"\$(git rev-parse --show-toplevel)\" commit from sub/" 2 \
  'git -C "$(git rev-parse --show-toplevel)" commit -m x' "$D/gitfail/sub" "FAILING-SUITE-MARKER" "@D@/gitfail|test"
precommit "ROOT=\$(git rev-parse --show-toplevel) && cd \"\$ROOT\"" 2 \
  'ROOT=$(git rev-parse --show-toplevel) && cd "$ROOT" && git commit -m x' "$D/gitfail/sub" "FAILING-SUITE-MARKER"
precommit "unquoted cd \$(git rev-parse --show-toplevel)" 2 \
  'cd $(git rev-parse --show-toplevel) && git commit -m x' "$D/gitfail/sub" "FAILING-SUITE-MARKER"
precommit "git -C sub rev-parse --show-toplevel resolves from -C" 2 \
  'cd "$(git -C @D@/gitfail/sub rev-parse --show-toplevel)" && git commit -m x' "$D/work" "FAILING-SUITE-MARKER"
precommit "rev-parse outside any repo stays unknown (skipped)" 0 \
  'cd "$(git rev-parse --show-toplevel)" && git commit -m x' "$D/work" "" NOMAKE
precommit "git -C \"\$CLAUDE_PROJECT_DIR/../failrepo\" (environment)" 2 \
  'git -C "$CLAUDE_PROJECT_DIR/../failrepo" commit -m x' "$D/work" "FAILING-SUITE-MARKER" "@D@/failrepo|test"
out=$(printf 'not-json' | HOME="$D/home" "$RUBY" -E UTF-8 "$PRECOMMIT" 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "malformed payload (pre-commit hook)" "rc=0" \
  || bad "malformed payload (pre-commit hook)" "rc=$rc :: $out"

echo "== git-command.rb: effective directory resolution"
dirs() { # dirs <name> <command> <expected space-joined dirs of commit invocations>
  local got
  got=$("$RUBY" -r"$HOOKS/git-command.rb" -e \
    'puts GitCommand.parse(ARGV[0], cwd: "/w", home: "/h").commits.map { |i| i.dir || "?" }.join(" ")' "$2" 2>&1)
  if [ "$got" = "$3" ]; then ok "$1" "$got"; else bad "$1" "want='$3' got='$got'"; fi
}
dirs "repeated -C is cumulative" 'cd /a && git -C b -C ../c commit' "/a/c"
dirs "subshell cd does not leak" 'cd /a; (cd /b && git commit); git commit' "/b /a"
dirs "cd inside a pipeline does not count" 'cd /a | git commit' "/w"
dirs "pushd / popd" 'pushd /p && git commit && popd && git commit' "/p /w"
dirs "--git-dir / --work-tree leave dir alone" 'git --git-dir=/x/.git --work-tree /x commit' "/w"
dirs "bash -c with cd" 'bash -c "cd sub && git commit"' "/w/sub"
dirs "tilde in cd" 'cd ~/r && git commit' "/h/r"
dirs "unknown \$VAR dir" 'cd "$X" && git commit' "?"
dirs "commit-tree is not commit" 'git commit-tree HEAD^{tree} -m x' ""
dirs "git commit in \$(...)" 'echo "$(git -C /s commit -m x)"' "/s"
dirs "variable in cd and -C" "R=\"$D/passrepo\"; cd \"\$R\" && S=sub; git -C \"\${S}\" commit" "$D/passrepo/sub"
dirs "assignment in a subshell does not leak" '(R=/r); git -C "$R" commit' "?"
dirs "assignment in a pipeline does not persist" 'R=/r | true; git -C "$R" commit' "?"
dirs "prefix assignment applies to that command only" 'R=/r true; git -C "$R" commit' "?"
dirs "tilde in an assignment" 'R=~/r; git -C "$R" commit' "/h/r"
dirs "-C behind an unknown wrapper (flock)" 'flock /l git -C /x commit' "/x"
dirs "remote wrapper: -C names the other host" 'docker exec c git -C /x commit' "?"
dirs "\$HOME and \${HOME}" 'git -C "$HOME/r" commit; cd ${HOME}/s && git commit' "/h/r /h/s"
dirs "\$PWD and \$(pwd) follow cd" 'cd /a && git -C "$PWD/b" commit && git -C "$(pwd)/c" commit' "/a/b /a/c"
dirs "\${UNSET:-default} and \${UNSET-default}" \
  'git -C "${UNSET_COMMIT_HOOK_TEST_VAR:-/d}" commit; git -C ${UNSET_COMMIT_HOOK_TEST_VAR-/e} commit' "/d /e"
dirs "assigned value wins over the default" 'R=/r; git -C "${R:-/d}" commit' "/r"
dirs "\$(other command) stays unknown" 'cd "$(dirname /x/y)" && git commit' "?"

echo "== Ruby 2.6 API surface (filter_map / tally removed, as on CRuby 2.6)"
if grep -nE '\.(filter_map|tally)\b' "$HOOKS/git-command.rb" "$BLOCK" "$PRECOMMIT"; then
  bad "no filter_map / tally in the hooks" "found (2.7+ only)"
else
  ok "no filter_map / tally in the hooks" "none"
fi
cat > "$D/ruby26.rb" <<'EOF'
module Enumerable
  %i[filter_map tally].each { |m| undef_method(m) if method_defined?(m) }
end
[Array, Hash, Struct, Range, Enumerator::Lazy].each do |k|
  k.send(:undef_method, :filter_map) if k.instance_methods(false).include?(:filter_map)
end
EOF
PRELOAD=(-r "$D/ruby26.rb")
pair "2.6: echo ... | git commit -F -" 'echo "@T@" | git commit -F -'
pair "2.6: cd repo && git commit -F - < rel" 'cd @D@/repo && git commit -F - < @F@'
pair "2.6: cat > new <<EOF, then -F new" "cat > @D@/work/new-msg26.txt <<'EOF'
fix: thing

@T@
EOF
git commit -F new-msg26.txt"
pair "2.6: MSG=\$(cat file); -m \"\$MSG\"" 'MSG=$(cat @D@/repo/@F@); git commit -m "$MSG"'
expect_allow "2.6: git commit && git log --grep=trailer" 'git commit -m fix && git log --grep="Co-Authored-By"'
precommit "2.6: plain git commit in failing cwd" 2 'git commit -m x' "$D/failrepo" "FAILING-SUITE-MARKER"
precommit "2.6: git -C failrepo commit from another cwd" 2 'git -C @D@/failrepo commit -m x' "$D/work" "FAILING-SUITE-MARKER"
PRELOAD=()

# Root-cause regressions live separately from the original SH1-79 baseline.
source "$(dirname "${BASH_SOURCE[0]}")/test-commit-hooks-sh1-86.sh"

echo "---- pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
