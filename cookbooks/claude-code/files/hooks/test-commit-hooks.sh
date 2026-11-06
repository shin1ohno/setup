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
# not list (xargs, mise exec --, flock, find -exec), commits in a shell
# started through su / runuser / sudo (-iu, -Hu, -s <<EOF) / script -qc or any
# other command (flock bash -c, xargs sh -c, find -exec sh -c, ssh host bash
# -s), su / sudo / script behind such a command (flock su -c, pct exec -- su
# -c, xargs su -c, setsid su <<EOF, flock script -qc), ssh's remote command
# string (`ssh host 'bash -s' <<EOF`, `ssh pve "pct exec 104 -- bash -s"
# <<EOF`, `ssh host sudo -s <<EOF`, a quoted `cd x && git commit`, a login
# shell reading the heredoc), a -c script reading its shell's stdin (`bash -c
# 'git commit -F -' <<EOF`), a pipe or && split across lines, a for loop over
# several messages, values held in variables the command sets, -F /dev/stdin
# and $(cat file), message paths through $HOME / $TMPDIR / $PWD / $(pwd) /
# $CLAUDE_PROJECT_DIR / ${NAME:-default} (the hook runs with HOME, TMPDIR and
# CLAUDE_PROJECT_DIR set to scratch dirs), a $(mktemp) message file, a file
# copied with `cat src > msg`, -F <(...) / --file=<(...) / < <(...), and
# { ...; } / ( ... ) group output piped or redirected into the message. The
# block hook fails closed (SH1-86): a message file written or on disk under an
# unknown cwd (`cd A 2>/dev/null || cd B`, if / else, case arms, `cd
# "$(mktemp -d)"`, `cd "$UNSET"`, `cd -`, a heredoc file inside `ssh host bash
# -s <<EOF` or `pct exec -- bash -c`), and a commit in a nested command string
# no model covers (flock -c / --command, sg -c, watch, parallel :::, tmux
# send-keys, trap, git rebase -x, osascript -e, python3 -c os.system, a
# script's arguments, an unknown `foo --run '...'`), a function body, a
# variable reassigned in a branch, $VAR in an unquoted heredoc and `<<<
# "$(cat f)"` all block; the text of data commands (gh --body / -b, git notes
# / log / show / grep, cat > docs <<EOF, printf / echo, jq --arg, curl -d,
# wget --post-data, logger, sed / awk programs, `xargs echo`, `find -exec
# grep`) and text that does not lex do not. Then
# allow-only cases: the trailer outside any git commit (echo, git log --grep,
# grep -r, a comment, hg commit, a doc heredoc next to `done < <(ls)`, a group
# member piped or redirected elsewhere, a shell name that is only an argument
# such as `gh ... --label bash` or an option's value (`shellcheck -s bash -`,
# `bat -l sh`, `--shell=/bin/bash`), a file named su / bash written by tee,
# a document or file written through ssh, `ssh -n`, ...), the trailer only in
# the source of a $(...) whose output is not literal (an amend that strips it), an unset
# $NAME whose NAME appears only inside another quoted string, a stale message
# file the command overwrites with clean literal text first, and 5000-deep
# nesting, which must exit 0 rather than crash.
#
# pre-commit-test: a fake `make` on PATH logs every call. A repo whose
# `make test` fails must block a commit addressed to it from ANOTHER cwd
# (git -C, the add/commit chain, cd, bash -c, su -c, su <<EOF, sudo -iu,
# sudo -s <<EOF, flock bash -c, flock su -c, xargs sudo -iu, setsid su
# <<EOF, a wrapper, -C "$R", --work-tree, cd / -C "$(git rev-parse
# --show-toplevel)" from a subdirectory of a real git repo, each repo of a
# for loop over several dirs); a passing repo exits 0 after running its
# tests; a command with no commit (or a --git-dir-only / remote commit, also
# in a shell behind ssh / docker / pct, in ssh's remote command string, or
# behind a later ssh / docker word such as `xargs ssh` / `caffeinate ssh` /
# `stdbuf docker exec`, and a commit only inside a snippet given to
# `shellcheck -s bash -`) exits 0 without calling make, and so does a commit
# after a cd chosen by `||` (also with the newline after it), if / else or
# case arms (its directory is unknown), rather than test the other directory,
# and an uncertain commit in a nested command string (`flock L -c '...'`,
# `watch '...'`, `git rebase -x '...'`: the documented skip), while `flock L
# bash -c '...'` stays tested.
#
# The git-command.rb sections check each commit's effective directory, its
# dir_candidates / certain flags, and the path keys of writes under an
# unknown cwd.
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
  "$D/gitrepo/sub" "$D/gitfail/sub"

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
# A stale message file from an earlier attempt, still carrying the trailer.
printf 'fix: thing\n\n%s\n' "$BAD_T" > "$D/work/stale.txt"
# The home directory sudo -i / su - start in (dirs cases).
ROOT_HOME=$("$RUBY" -e 'print Dir.home("root")')

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

echo "== block-co-authored-by: shell started through su / runuser / sudo / another command"
pair "su - root -c '...'" "su - root -c 'git -C @D@/repo commit -m fix -m \"@T@\"'"
pair "su -lc '...' root (option cluster)" "su -lc 'git commit -m fix -m \"@T@\"' root"
pair "su root <<'EOF' (the shell reads the heredoc)" "su root <<'EOF'
cd @D@/repo && git commit -m fix -m \"@T@\"
EOF"
pair "runuser -u root -- bash -c '...'" "runuser -u root -- bash -c 'git commit -m fix -m \"@T@\"'"
pair "runuser -u root -- git commit" 'runuser -u root -- git commit -m fix -m "@T@"'
pair "flock f bash -c '...'" "flock @D@/work/lock bash -c 'git commit -m fix -m \"@T@\"'"
pair "xargs -I{} sh -c '...'" "echo @D@/repo | xargs -I{} sh -c 'git -C {} commit -m fix -m \"@T@\"'"
pair "find -exec sh -c '...' _ {} \\;" \
  "find @D@/repo -maxdepth 0 -exec sh -c 'cd \"\$1\" && git commit -m fix -m \"@T@\"' _ {} \\;"
pair "script -qc '...' /dev/null" "script -qc 'git commit -m fix -m \"@T@\"' /dev/null"
pair "setsid ionice -c3 bash -c '...'" "setsid ionice -c3 bash -c 'git commit -m fix -m \"@T@\"'"
pair "sudo -iu root bash -lc '...'" "sudo -iu root bash -lc 'git commit -m fix -m \"@T@\"'"
pair "sudo -Hu root sh -c '...'" "sudo -Hu root sh -c 'git commit -m fix -m \"@T@\"'"
pair "sudo -uroot sh -c '...' (attached value)" "sudo -uroot sh -c 'git commit -m fix -m \"@T@\"'"
pair "sudo -s <<'EOF' (the shell reads the heredoc)" "sudo -s <<'EOF'
git -C @D@/repo commit -m fix -m \"@T@\"
EOF"
pair "ssh host bash -s <<'EOF' (remote: message still checked)" "ssh host bash -s <<'EOF'
cd /srv/repo && git commit -m fix -m \"@T@\"
EOF"

echo "== block-co-authored-by: su / sudo / script behind another command; ssh's remote command"
pair "flock f su - root -c '...'" "flock @D@/work/lock su - root -c 'cd @D@/repo && git commit -m fix -m \"@T@\"'"
pair "pct exec 104 -- su - root -c '...' (remote)" "pct exec 104 -- su - root -c 'cd ~ && git commit -m fix -m \"@T@\"'"
pair "docker exec c su - root -c '...' (remote)" "docker exec c su - root -c 'git commit -m fix -m \"@T@\"'"
pair "xargs -I{} su root -c '...'" "echo x | xargs -I{} su root -c 'git commit -m fix -m \"@T@\"'"
pair "setsid -w su root <<'EOF' (the shell reads the heredoc)" "setsid -w su root <<'EOF'
git commit -m fix -m \"@T@\"
EOF"
pair "flock f script -qc '...' /dev/null" "flock @D@/work/lock script -qc 'git commit -m fix -m \"@T@\"' /dev/null"
pair "xargs sudo -iu root bash -c '...'" "echo x | xargs sudo -iu root bash -c 'git commit -m fix -m \"@T@\"'"
pair "ssh host sudo -s <<'EOF' (remote)" "ssh host sudo -s <<'EOF'
git commit -m fix -m \"@T@\"
EOF"
pair "ssh host 'bash -s' <<'EOF' (quoted remote shell)" "ssh host 'bash -s' <<'EOF'
git commit -m fix -m \"@T@\"
EOF"
pair "ssh pve \"pct exec 104 -- bash -s\" <<'EOF'" "ssh pve \"pct exec 104 -- bash -s\" <<'EOF'
cd /root/x && git commit -m fix -m \"@T@\"
EOF"
pair "ssh -p 22 host -t 'cd x && git commit ...' (remote command string)" \
  "ssh -p 22 host -t 'cd /srv/repo && git commit -m fix -m \"@T@\"'"
pair "ssh host <<'EOF' (the login shell reads the heredoc)" "ssh host <<'EOF'
cd /srv/repo && git commit -m fix -m \"@T@\"
EOF"
pair "ssh host 'git commit -F -' <<'EOF' (the remote command reads ssh's stdin)" "ssh host 'git commit -F -' <<'EOF'
fix: thing

@T@
EOF"
pair "bash -c 'git commit -F -' <<'EOF' (the -c script reads the shell's stdin)" "bash -c 'git commit -F -' <<'EOF'
fix: thing

@T@
EOF"
pair "caffeinate -i ssh host bash -s <<'EOF' (remote behind a wrapper)" "caffeinate -i ssh host bash -s <<'EOF'
git commit -m fix -m \"@T@\"
EOF"
expect_allow "ssh host 'tee notes.md' <<EOF (a document, not a script)" "ssh host 'tee /tmp/notes.md' <<'EOF'
cd /srv/repo && git commit -m fix -m \"$BAD_T\"
EOF"
expect_allow "ssh host 'cat > x.sh' <<EOF (a file being written)" "ssh host 'cat > /tmp/x.sh' <<'EOF'
git commit -m fix -m \"$BAD_T\"
EOF"
expect_allow "ssh host \"echo '...' >> notes\" (data command)" \
  "ssh host \"echo 'git commit -m \\\"$BAD_T\\\"' >> notes\""
expect_allow "ssh host \"echo git commit -m trailer\" (data command)" \
  "ssh host \"echo git commit -m Co-Authored-By: Claude\""
expect_allow "ssh -n host bash -s <<EOF (stdin is /dev/null)" "ssh -n host bash -s <<'EOF'
git commit -m fix -m \"$BAD_T\"
EOF"
expect_allow "tee f/su <<EOF (a file named su is data)" "tee @D@/work/su <<'EOF'
git commit -m fix -m \"$BAD_T\"
EOF"
expect_allow "tee f/bash <<EOF (a file named bash is data)" "tee @D@/work/bash <<'EOF'
git commit -m fix -m \"$BAD_T\"
EOF"

echo "== block-co-authored-by: a shell name that is an option's value is not a shell"
expect_allow "shellcheck -s bash - <<'EOF'" "shellcheck -s bash - <<'EOF'
git commit -m fix -m \"$BAD_T\"
EOF"
expect_allow "bat -l sh <<'EOF'" "bat -l sh <<'EOF'
git commit -m \"$BAD_T\"
EOF"
expect_allow "pygmentize -l bash <<'EOF'" "pygmentize -l bash <<'EOF'
git commit -m \"$BAD_T\"
EOF"
expect_allow "shfmt -ln bash <<'EOF'" "shfmt -ln bash <<'EOF'
git commit -m \"$BAD_T\"
EOF"
expect_allow "tool --shell bash <<'EOF'" "npx tsx gen.ts --shell bash <<'EOF'
git commit -m \"$BAD_T\"
EOF"
expect_allow "tool --shell=/bin/bash <<'EOF'" "npx some-tool --shell=/bin/bash <<'EOF'
git commit -m \"$BAD_T\"
EOF"
expect_allow "shellcheck -s sh - <<< '...'" "shellcheck -s sh - <<< 'git commit -m \"$BAD_T\"'"
expect_allow "printf ... | shellcheck -s bash -" "printf '%s\\n' 'git commit -m \"$BAD_T\"' | shellcheck -s bash -"
pair "docker exec -i c sh <<'EOF' (a shell, not an option value)" "docker exec -i c sh <<'EOF'
git commit -m fix -m \"@T@\"
EOF"
pair "kubectl exec -i pod -- bash <<'EOF'" "kubectl exec -i pod -- bash <<'EOF'
git commit -m fix -m \"@T@\"
EOF"
pair "setsid -f bash -c '...' (-c after an option is kept)" "setsid -f bash -c 'git commit -m fix -m \"@T@\"'"
pair "printf x | xargs -0 bash -c '...'" "printf x | xargs -0 bash -c 'git commit -m fix -m \"@T@\"'"

echo "== block-co-authored-by: a newline after | || && continues the command; for over several items"
pair "printf ... |<newline> git commit -F -" "printf 'fix\\n\\n%s\\n' '@T@' |
  git commit -F -"
pair "{ ...; } |<newline> git commit -F -" "{ echo fix; echo; echo '@T@'; } |
  git commit -F -"
pair "echo 'git commit ...' |<newline> bash" "echo 'git commit -m fix -m \"@T@\"' |
  bash"
pair "cd repo &&<newline> git commit -F rel" "cd @D@/repo &&
  git commit -F @F@"
pair "for M in fix \"...\"; do git commit -m \"\$M\" (each item)" 'for M in fix "@T@"; do git commit -m "$M"; done'
expect_allow "echo \"su - root -c 'git commit ...'\" (data command)" \
  "echo \"su - root -c 'git commit -m fix -m \\\"$BAD_T\\\"'\""
expect_allow "gh issue create --label bash --body-file - <<EOF (data)" \
  "gh issue create --title x --label bash --body-file - <<'EOF'
Never run git commit -m \"$BAD_T\".
EOF"
expect_allow "tool --label sh --body-file - <<EOF (a shell name as an argument)" \
  "mytool --label sh --body-file - <<'EOF'
git commit -m \"$BAD_T\"
EOF"
expect_allow "printf ... | xargs -0 bash (xargs' stdin is its data)" \
  "printf 'git commit -m \"%s\"' '$BAD_T' | xargs -0 bash"

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
expect_block "unmodeled assignment (mapfile) inside bash -c, then \$MSG" "bash -c 'mapfile -t MSG <<EOF
$BAD_T
EOF
git commit -m \"\$MSG\"'"
expect_allow "unset \$NAME; NAME only inside another quoted string" \
  'git commit -m "bump $HOOK_TEST_UNSET_VERSION" && echo "HOOK_TEST_UNSET_VERSION bumped; no Co-Authored-By added"'

echo "== block-co-authored-by: the trailer only in the source of a \$(...)"
expect_allow "amend: MSG=\$(git log | grep -v trailer); -m \"\$MSG\"" \
  "MSG=\$(git log -1 --format=%B | grep -v '^Co-Authored-By:'); git commit --amend -m \"\$MSG\""
expect_allow "amend: MSG=\"\$(git log | sed '/trailer/Id')\" + newline + -m" \
  "MSG=\"\$(git log -1 --format=%B | sed '/^Co-Authored-By/Id')\"
git commit --amend -m \"\$MSG\""
expect_allow "amend: -m \"\$(git log | grep -v trailer)\"" \
  "git commit --amend -m \"\$(git log -1 --format=%B | grep -v '^Co-Authored-By:')\""
pair "-m \"\$(echo '...')\" (literal output still checked)" "git commit -m \"\$(echo '@T@')\""
pair "MSG=\$(cat <<'EOF' ... EOF) (literal output still checked)" "MSG=\$(cat <<'EOF'
fix: (thing)

@T@
EOF
)
git commit -m \"\$MSG\""
pair "text around a \$(...) is still the message" "git commit -m \"fix \$(date) @T@\""

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

echo "== block-co-authored-by: a message file overwritten or copied by the same command"
expect_allow "stale file overwritten by printf > first" "printf 'fix: clean\\n' > stale.txt && git commit -F stale.txt"
expect_allow "stale file overwritten by cat > <<'EOF' first" "cat > stale.txt <<'EOF'
fix: clean
EOF
git commit -F stale.txt"
expect_allow "stale file overwritten by ... | tee first" "printf 'fix: clean\\n' | tee stale.txt && git commit -F stale.txt"
expect_block "stale file appended to (>>) still blocks" "printf 'fix\\n' >> stale.txt && git commit -F stale.txt"
expect_block "stale file appended to (tee -a) still blocks" "printf 'fix\\n' | tee -a stale.txt && git commit -F stale.txt"
expect_block "stale file overwritten only after the commit still blocks" \
  "git commit -F stale.txt && printf 'fix\\n' > stale.txt"
expect_block "stale file overwritten only in an || branch still blocks" \
  "[ -s stale.txt ] || printf 'fix\\n' > stale.txt; git commit -F stale.txt"
expect_block "stale file overwritten only in an if branch still blocks" \
  "if [ ! -s stale.txt ]; then printf 'fix\\n' > stale.txt; fi; git commit -F stale.txt"
pair "cat src > msg, then -F msg (the copy)" "cat @D@/repo/@F@ > @D@/work/copy-msg.txt && git commit -F copy-msg.txt"
pair "cat < src > msg, then -F msg" "cat < @D@/repo/@F@ > @D@/work/copy-msg2.txt && git commit -F copy-msg2.txt"
pair "cat src > stale, then -F stale (the copy, not the stale file)" \
  "cat @D@/repo/@F@ > stale.txt && git commit -F stale.txt"

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

echo "== block-co-authored-by: an unknown cwd (cd in a branch, unresolved cd, remote) is still checked"
pair "cd A 2>/dev/null || cd B; cat > m <<EOF; git commit -F m" "cd @D@/nonexistent 2>/dev/null || cd @D@/repo
cat > br-msg.txt <<'EOF'
fix: thing

@T@
EOF
git add -A && git commit -F br-msg.txt"
pair "if/else cd; printf > m; git commit -F m" "if [ -d @D@/repo ]; then cd @D@/repo; else cd @D@/home; fi
printf 'fix\\n\\n%s\\n' '@T@' > .git-br-msg
git commit -F .git-br-msg"
pair "case arms cd; cat > m <<EOF; git commit -F m" "case \"\$(uname)\" in Linux) cd @D@/repo ;; *) cd @D@/home ;; esac
cat > br-msg3.txt <<'EOF'
fix: thing

@T@
EOF
git commit -F br-msg3.txt"
pair "cd A 2>/dev/null || cd repo; -F rel on disk (each branch's dir)" \
  'cd @D@/nonexistent 2>/dev/null || cd @D@/repo; git commit -F @F@'
pair "cd A 2>/dev/null || cd repo; -m \"\$(cat rel)\"" \
  'cd @D@/nonexistent 2>/dev/null || cd @D@/repo; git commit -m fix -m "$(cat @F@)"'
pair "if [ -d repo ]; then cd repo; fi; -F - < rel" 'if [ -d @D@/repo ]; then cd @D@/repo; fi; git commit -F - < @F@'
expect_block "both cds may fail: -F rel read in the entry dir too" \
  'cd @D@/nonexistent 2>/dev/null || cd @D@/nonexistent2 2>/dev/null; git commit -F msg-cwd.txt'
expect_allow "stale file overwritten under the same unknown cwd first" \
  "cd @D@/nonexistent 2>/dev/null || cd @D@/work; printf 'fix: clean\\n' > stale.txt && git commit -F stale.txt"
pair "ssh host bash -s <<EOF with a heredoc message file inside" "ssh host bash -s <<'EOF'
cd /srv/repo
cat > m <<'MSG'
fix: thing

@T@
MSG
git commit -F m
EOF"
pair "pct exec 104 -- bash -c 'cd x && printf > .git/M && git commit -F .git/M'" \
  "pct exec 104 -- bash -c 'cd /root/setup && printf \"fix\\n\\n@T@\\n\" > .git/M && git commit -F .git/M'"
expect_allow "ssh host 'cd x && git commit -F m': m is on that host, not read here" \
  "ssh host 'cd @D@/repo && git commit -F msg-bad.txt'"
pair "cd \"\$(mktemp -d)\" && cat > m <<EOF && git commit -F m" "cd \"\$(mktemp -d)\" && git init -q && cat > m <<'EOF'
fix: thing

@T@
EOF
git commit --allow-empty -F m"
pair "cd \"\$UNSET\"; cat > m <<EOF; git commit -F m" "cd \"\$UNSET_COMMIT_HOOK_TEST_DIR\"; cat > m <<'EOF'
fix: thing

@T@
EOF
git commit -F m"
pair "cd -; cat > m <<EOF; git commit -F m" "cd -; cat > m <<'EOF'
fix: thing

@T@
EOF
git commit -F m"

echo "== block-co-authored-by: a commit in a command string no model covers (uncertain, still checked)"
pair "flock L -c 'git commit ...'" "flock @D@/work/lock -c 'git commit -m x -m \"@T@\"'"
pair "flock -n -w 5 L --command '...'" "flock -n -w 5 @D@/work/lock --command 'git commit -m x -m \"@T@\"'"
pair "timeout 30 flock -w 5 L -c '...'" "timeout 30 flock -w 5 @D@/work/lock -c 'git commit -m x -m \"@T@\"'"
pair "flock L -c 'git commit -F -' <<EOF (the string reads the stdin)" "flock @D@/work/lock -c 'git commit -F -' <<'EOF'
fix: thing

@T@
EOF"
pair "flock L -c 'cd repo && git commit -F rel' (its own cd)" "flock @D@/work/lock -c 'cd @D@/repo && git commit -F @F@'"
pair "sg grp -c '...'" "sg wheel -c 'git commit -m x -m \"@T@\"'"
pair "watch -n1 'git commit ...'" "watch -n1 'git commit -m x -m \"@T@\"'"
pair "parallel ::: 'git commit ...'" "parallel ::: 'git commit -m x -m \"@T@\"'"
pair "unknown wrapper: foo --run 'git commit ...'" "foo --run 'git commit -m x -m \"@T@\"'"
pair "tmux send-keys -t s 'git commit ...' Enter" "tmux send-keys -t s 'git commit -m x -m \"@T@\"' Enter"
pair "git rebase -x 'git commit --amend ...'" "git rebase -x 'git commit --amend -m fix -m \"@T@\"' HEAD~1"
pair "trap 'git commit ...' EXIT" "trap 'git commit -m fix -m \"@T@\"' EXIT"
pair "osascript -e 'do shell script \"git commit ...\"' (not data)" \
  "osascript -e 'do shell script \"git commit -m fix -m \\\"@T@\\\"\"'"
pair "python3 -c 'os.system(\"git commit ...\")'" \
  "python3 -c 'import os; os.system(\"git commit -m fix -m \\\"@T@\\\"\")'"
pair "bash -c 'eval \"\$1\"' _ 'git commit ...' (a script's argument)" \
  "bash -c 'eval \"\$1\"' _ 'git commit -m fix -m \"@T@\"'"
pair "function NAME { git commit ...; }" 'function ci { git commit -m fix -m "@T@"; }; ci'
pair "MSG=...; if ...; then MSG=other; fi (the first value may stay)" \
  'MSG="@T@"; if [ -n "$UNSET_COMMIT_HOOK_TEST_VAR" ]; then MSG=fix; fi; git commit -m "$MSG"'
pair "TR=...; git commit -F - <<EOF with \$TR (unquoted heredoc)" "TR='@T@'
git commit -F - <<EOF
fix: thing

\$TR
EOF"
pair "-F - <<< \"\$(cat file)\"" 'git commit -F - <<< "$(cat @D@/repo/@F@)"'

echo "== block-co-authored-by: text that is data, not a nested script (allow)"
EX="git commit -m fix -m \"$BAD_T\""
expect_allow "gh pr create --body with a backticked example" "gh pr create --title x --body 'Example: \`$EX\`'"
expect_allow "gh issue comment -b with a backticked example" "gh issue comment 12 -b 'Do not run \`$EX\`'"
expect_allow "git notes add -m with the example" "git notes add -m 'never: $EX'"
expect_allow "git log --grep with the example" "git log --grep='$EX'"
expect_allow "git show --format with the example" "git show -s --format='$EX' HEAD"
expect_allow "git grep with the example" "git grep -n '$EX' -- '*.md'"
expect_allow "cat > docs.md <<EOF with the example" "cat > @D@/work/docs.md <<'EOF'
Never run \`$EX\`.
EOF"
expect_allow "printf the example into a file" "printf '%s\\n' '$EX' > @D@/work/doc.txt"
expect_allow "echo the example" "echo '$EX'"
expect_allow "jq -n --arg with the example" "jq -n --arg c '$EX' '{c: \$c}'"
expect_allow "curl -d with the example" "curl -sS -d '$EX' https://example.invalid/x"
expect_allow "wget --post-data with the example" "wget -q --post-data '$EX' https://example.invalid/x"
expect_allow "logger with the example" "logger -t note '$EX'"
expect_allow "sed program with the example" "sed -n '/$EX/p' @D@/work/doc.txt"
expect_allow "awk program with the example" "awk '/git commit/ { print \"$BAD_T\" }' @D@/work/doc.txt"
expect_allow "xargs echo '...' (a later data command's text)" "xargs echo '$EX' < /dev/null"
expect_allow "find -exec grep -l '...' {} + (a later data command's text)" "find . -name '*.md' -exec grep -l '$EX' {} +"
expect_allow "xargs git log --grep '...' (a later git data subcommand)" "xargs git log --grep '$EX' < /dev/null"
expect_allow "unknown command: argument names git commit, no trailer" "mytool --run 'git commit -m fix'"
expect_allow "nested text that does not lex is not a script" "mytool --note \"don't $EX\""
expect_allow "message mentions co-authored in prose (no -by)" 'git commit -m "docs: credit co-authored work in the changelog"'

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
precommit "su - root -c 'cd failrepo && git commit'" 2 \
  "su - root -c 'cd @D@/failrepo && git commit -m x'" "$D/work" "FAILING-SUITE-MARKER" "@D@/failrepo|test"
precommit "su root <<'EOF' cd failrepo && git commit" 2 "su root <<'EOF'
cd @D@/failrepo && git commit -m x
EOF" "$D/work" "FAILING-SUITE-MARKER" "@D@/failrepo|test"
precommit "flock f bash -c 'git -C failrepo commit'" 2 \
  "flock @D@/work/lock bash -c 'git -C @D@/failrepo commit -m x'" "$D/work" "FAILING-SUITE-MARKER" "@D@/failrepo|test"
precommit "sudo -iu root bash -lc 'cd failrepo && git commit'" 2 \
  "sudo -iu root bash -lc 'cd @D@/failrepo && git commit -m x'" "$D/work" "FAILING-SUITE-MARKER" "@D@/failrepo|test"
precommit "sudo -s <<'EOF' git -C failrepo commit" 2 "sudo -s <<'EOF'
git -C @D@/failrepo commit -m x
EOF" "$D/work" "FAILING-SUITE-MARKER" "@D@/failrepo|test"
precommit "xargs sh -c 'git -C failrepo commit'" 2 \
  "echo x | xargs sh -c 'git -C @D@/failrepo commit -m x'" "$D/work" "FAILING-SUITE-MARKER" "@D@/failrepo|test"
precommit "ssh host bash -s <<'EOF' (remote shell) runs no make" 0 "ssh host bash -s <<'EOF'
git -C @D@/failrepo commit -m x
EOF" "$D/work" "" NOMAKE
precommit "docker exec c sh -c 'cd failrepo && git commit' runs no make" 0 \
  "docker exec c sh -c 'cd @D@/failrepo && git commit -m x'" "$D/work" "" NOMAKE
precommit "echo \"su - root -c 'git commit'\" runs no make" 0 \
  "echo \"su - root -c 'git -C @D@/failrepo commit -m x'\"" "$D/work" "" NOMAKE
precommit "cd failrepo 2>/dev/null || cd passrepo; git commit: unknown dir, no make" 0 \
  'cd @D@/failrepo 2>/dev/null || cd @D@/passrepo; git commit -m x' "$D/work" "" NOMAKE
precommit "if [ -d failrepo ]; then cd failrepo; else cd passrepo; fi: no make" 0 \
  'if [ -d @D@/failrepo ]; then cd @D@/failrepo; else cd @D@/passrepo; fi; git commit -m x' "$D/work" "" NOMAKE
precommit "[ -d failrepo ] && cd failrepo || cd passrepo: no make" 0 \
  '[ -d @D@/failrepo ] && cd @D@/failrepo || cd @D@/passrepo; git commit -m x' "$D/work" "" NOMAKE
precommit "case arms cd to different repos: no make" 0 \
  'case "$X" in a) cd @D@/failrepo ;; *) cd @D@/passrepo ;; esac; git commit -m x' "$D/work" "" NOMAKE
precommit "cd failrepo || exit 1; git commit still tests failrepo" 2 \
  'cd @D@/failrepo || exit 1; git commit -m x' "$D/work" "FAILING-SUITE-MARKER" "@D@/failrepo|test"
precommit "if ...; then cd failrepo && git commit; fi tests failrepo" 2 \
  'if [ -d @D@/failrepo ]; then cd @D@/failrepo && git commit -m x; fi' "$D/work" "FAILING-SUITE-MARKER"
precommit "flock f su root -c 'cd failrepo && git commit'" 2 \
  "flock @D@/work/lock su root -c 'cd @D@/failrepo && git commit -m x'" "$D/work" "FAILING-SUITE-MARKER" "@D@/failrepo|test"
precommit "xargs sudo -iu root git -C failrepo commit" 2 \
  'xargs sudo -iu root git -C @D@/failrepo commit -m x < /dev/null' "$D/work" "FAILING-SUITE-MARKER" "@D@/failrepo|test"
precommit "setsid -w su root <<'EOF' cd failrepo && git commit" 2 "setsid -w su root <<'EOF'
cd @D@/failrepo && git commit -m x
EOF" "$D/work" "FAILING-SUITE-MARKER" "@D@/failrepo|test"
precommit "pct exec 104 -- su - root -c 'cd failrepo && git commit' (remote) runs no make" 0 \
  "pct exec 104 -- su - root -c 'cd @D@/failrepo && git commit -m x'" "$D/work" "" NOMAKE
precommit "ssh host 'cd failrepo && git commit' (remote) runs no make" 0 \
  "ssh host 'cd @D@/failrepo && git commit -m x'" "$D/work" "" NOMAKE
precommit "ssh host <<'EOF' cd failrepo && git commit (remote) runs no make" 0 "ssh host <<'EOF'
cd @D@/failrepo && git commit -m x
EOF" "$D/work" "" NOMAKE
precommit "xargs -I{} ssh {} bash -c 'cd failrepo && git commit' runs no make" 0 \
  "echo h1 | xargs -I{} ssh {} bash -c 'cd @D@/failrepo && git commit -m x'" "$D/work" "" NOMAKE
precommit "caffeinate -i ssh host bash -s <<'EOF' cd failrepo runs no make" 0 "caffeinate -i ssh host bash -s <<'EOF'
cd @D@/failrepo && git commit -m x
EOF" "$D/work" "" NOMAKE
precommit "stdbuf -oL docker exec c sh -c 'cd failrepo && git commit' runs no make" 0 \
  "stdbuf -oL docker exec c sh -c 'cd @D@/failrepo && git commit -m x'" "$D/work" "" NOMAKE
precommit "flock f ssh host git -C failrepo commit runs no make" 0 \
  'flock @D@/work/lock ssh host git -C @D@/failrepo commit -m x' "$D/work" "" NOMAKE
precommit "shellcheck -s bash - <<'EOF' with a commit inside runs no make" 0 "shellcheck -s bash - <<'EOF'
cd @D@/failrepo && git commit -m x
EOF" "$D/work" "" NOMAKE
precommit "cd failrepo 2>/dev/null ||<newline> cd passrepo; git commit: no make" 0 'cd @D@/failrepo 2>/dev/null ||
  cd @D@/passrepo
git commit -m x' "$D/work" "" NOMAKE
precommit "for d in passrepo failrepo; do git -C \"\$d\" commit: both tested" 2 \
  'for d in @D@/passrepo @D@/failrepo; do git -C "$d" commit -m x; done' "$D/work" "FAILING-SUITE-MARKER" "@D@/passrepo|test"
precommit "for d in failrepo passrepo; do cd \"\$d\" && git commit: tested" 2 \
  'for d in @D@/failrepo @D@/passrepo; do cd "$d" && git commit -m x; done' "$D/work" "FAILING-SUITE-MARKER" "@D@/failrepo|test"
precommit "cd D && for d in passrepo failrepo; do git -C \$d commit" 2 \
  'cd @D@ && for d in passrepo failrepo; do git -C $d commit -m x; done' "$D/work" "FAILING-SUITE-MARKER" "@D@/passrepo|test"
precommit "for d in gitrepo passrepo; do git -C \"\$d\" commit: passes after testing" 0 \
  'for d in @D@/gitrepo @D@/passrepo; do git -C "$d" commit -m x; done' "$D/work" "" "@D@/passrepo|test"
precommit "flock L -c 'git -C failrepo commit' (uncertain): documented skip, no make" 0 \
  "flock @D@/work/lock -c 'git -C @D@/failrepo commit -m x'" "$D/work" "" NOMAKE
precommit "watch -n1 'cd failrepo && git commit' (uncertain): no make" 0 \
  "watch -n1 'cd @D@/failrepo && git commit -m x'" "$D/work" "" NOMAKE
precommit "git rebase -x 'git -C failrepo commit --amend' (uncertain): no make" 0 \
  "git rebase -x 'git -C @D@/failrepo commit --amend --no-edit' HEAD~1" "$D/work" "" NOMAKE
precommit "cd failrepo || cd passrepo; git commit: never tests passrepo only" 0 \
  'cd @D@/failrepo || cd @D@/passrepo; git commit -m x' "$D/work" "" NOMAKE
precommit "cd A 2>/dev/null || cd passrepo; cat > m <<EOF; git commit -F m: no make" 0 "cd @D@/nonexistent 2>/dev/null || cd @D@/passrepo
cat > m <<'EOF'
fix
EOF
git commit -F m" "$D/work" "" NOMAKE
precommit "cd \"\$(mktemp -d)\"; cd failrepo && git commit: the absolute cd is known" 2 \
  'cd "$(mktemp -d)"; cd @D@/failrepo && git commit -m x' "$D/work" "FAILING-SUITE-MARKER" "@D@/failrepo|test"
precommit "flock L bash -c 'git -C failrepo commit' stays certain and tested" 2 \
  "flock -n @D@/work/lock bash -c 'git -C @D@/failrepo commit -m x'" "$D/work" "FAILING-SUITE-MARKER" "@D@/failrepo|test"
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
dirs "variable in cd and -C" 'R=/r; cd "$R" && S=sub; git -C "${S}" commit' "/r/sub"
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
dirs "cd A || cd B: unknown; cd A || exit: A" 'cd /a 2>/dev/null || cd /b; git commit; cd /c || exit 1; git commit' "? /c"
dirs "cd A || cd B && git commit: unknown" 'cd /a || cd /b && git commit' "?"
dirs "if / else: known inside a branch, unknown after fi" \
  'if t; then cd /a && git commit; else cd /b; fi; git commit' "/a ?"
dirs "if / elif / else all ending in one dir" 'if t; then cd /a; elif u; then cd /a; else cd /a; fi; git commit' "/a"
dirs "if without else: the branch may not run" 'if t; then cd /a; fi; git commit' "?"
dirs "if cd A; then ...: the condition runs" 'if cd /a; then git commit; fi' "/a"
dirs "case arms; *) makes them exhaustive" \
  'case $x in a) cd /a;; *) cd /a;; esac; git commit; case $x in a|b) cd /b;; esac; git commit' "/a ?"
dirs "case ) inside a subshell closes no scope" '(case $x in a) cd /b;; esac; git commit); git commit' "? /w"
dirs "loop body cd: unknown after done" 'while t; do cd /a; done; git commit' "?"
dirs "|| inside ( ) does not leak" 'cd /a; (cd /b || cd /c); git commit' "/a"
dirs "pushd A || pushd B; popd: unknown" 'pushd /a || pushd /b; popd; git commit' "?"
dirs "su - USER / sudo -i start in its home; -D wins; su keeps cwd" \
  'su - root -c "git commit"; sudo -iu root git commit; sudo -i -D /d git commit; su root -c "git commit"' \
  "$ROOT_HOME $ROOT_HOME /d /w"
dirs "HOME=x bash -c 'cd ~' uses that HOME" "HOME=/x bash -c 'cd ~ && git commit'" "/x"
dirs "runuser -u root -- git -C /x commit" 'runuser -u root -- git -C /x commit' "/x"
dirs "shell behind ssh / docker: unknown, cd and -C included" \
  "ssh h bash -c 'cd /x && git commit'; docker exec c sh -c 'git -C /x commit'" "? ?"
dirs "su / sudo / runuser / script / env behind flock or xargs" \
  "flock /l su - root -c 'git commit'; flock /l sudo -D /d git commit; xargs env -C /e git commit; flock /l runuser -u root -- git -C /x commit; flock /l script -qc 'cd /s && git commit' /dev/null" \
  "$ROOT_HOME /d /e /x /s"
dirs "ssh: options, the remote string, a later ssh / docker word: unknown" \
  "ssh -o BatchMode=yes -i k h -- git -C /x commit; ssh h 'cd /x && git commit'; flock /l ssh h git -C /x commit; stdbuf -oL docker exec c sh -c 'git -C /x commit'; pct exec 104 -- su - root -c 'cd /x && git commit'" \
  "? ? ? ? ?"
dirs "a shell name after an option keeps its -c script" "tool --shell bash -c 'cd /t && git commit'" "/t"
dirs "newline after || && | continues the command" \
  $'cd /a 2>/dev/null ||\n  cd /b\ngit commit; cd /c &&\n  git commit; true | # note\n  git commit' "? /c /c"
dirs "for over static items: the body once per item" \
  'for d in /a /b; do cd "$d"; git commit; done; git commit' "/a /b ?"
dirs "for: each run starts where the last one ended" 'for d in a b; do cd $d && git commit; done' "/w/a /w/a/b"
dirs "for: nested loops, and items with a space" \
  'for d in a b; do for e in c d; do git -C $d/$e commit; done; done; for d in "x y" z; do git -C "$d" commit; done' \
  "/w/a/c /w/a/d /w/b/c /w/b/d /w/x y /w/z"
dirs "for: a glob or unknown item keeps the joined value" \
  'for d in *.x y; do git -C "$d" commit; done; for d in $X y; do git -C "$d" commit; done' "/w/*.x y ?"

echo "== git-command.rb: uncertainty reporting (dir | dir_candidates | certain)"
cands() { # cands <name> <command> <expected "dir|candidates|certain" per commit, joined by " ; ">
  local got
  got=$("$RUBY" -r"$HOOKS/git-command.rb" -e '
    r = GitCommand.parse(ARGV[0], cwd: "/w", home: "/h")
    puts r.commits.map { |i| "#{i.dir || "?"}|#{i.dir_candidates.join(" ")}|#{i.certain ? "certain" : "uncertain"}" }.join(" ; ")' "$2" 2>&1)
  if [ "$got" = "$3" ]; then ok "$1" "$got"; else bad "$1" "want='$3' got='$got'"; fi
}
cands "definite dir: itself" 'cd /a && git commit' "/a|/a|certain"
cands "cd A || cd B: both branches and the entry" 'cd /a 2>/dev/null || cd /b; git commit' "?|/a /b /w|certain"
cands "if without else: the branch and the entry" 'if t; then cd /a; fi; git commit' "?|/a /w|certain"
cands "case arms: each arm and the entry" 'case $x in a) cd /a;; b) cd /b;; esac; git commit' "?|/a /b /w|certain"
cands "a relative cd after a merge applies to each candidate" 'cd /a || cd /b; cd sub; git commit' \
  "?|/a/sub /b/sub /w/sub|certain"
cands "unresolved cd target: nothing knowable" 'cd "$X"; git commit; cd -; git commit' "?||certain ; ?||certain"
cands "an absolute cd after an unknown one is known again" 'cd "$X"; cd /b && git commit' "/b|/b|certain"
cands "remote: no local candidates" "ssh h 'cd /x && git commit'; docker exec c git -C /x commit" \
  "?||certain ; ?||certain"
cands "nested command string: uncertain" "flock L -c 'cd /x && git commit'; watch 'git commit'" \
  "?||uncertain ; ?||uncertain"
cands "explicit models stay certain" "flock L bash -c 'git -C /x commit'; su root -c 'cd /y && git commit'" \
  "/x|/x|certain ; /y|/y|certain"
keys() { # keys <name> <command> <expected space-joined write keys>
  local got
  got=$("$RUBY" -r"$HOOKS/git-command.rb" -e '
    puts GitCommand.parse(ARGV[0], cwd: "/w", home: "/h").writes.keys.join(" ")' "$2" 2>&1)
  if [ "$got" = "$3" ]; then ok "$1" "$got"; else bad "$1" "want='$3' got='$got'"; fi
}
keys "write under an unknown cwd: its token key" $'cd /a || cd /b; echo x > m; cd sub && echo y > ./n/../o' "<?1>/m <?1>/sub/o"
keys "write under an unresolved cd: the target text" $'cd "$(mktemp -d)" && echo x > m' '$(mktemp -d)/m'
keys "write in a remote shell: the remote root" "ssh h 'cd /srv && echo x > m'" "<remote>/srv/m"

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
pair "2.6: su - root -c '...'" "su - root -c 'git commit -m fix -m \"@T@\"'"
expect_allow "2.6: stale file overwritten by printf > first" "printf 'fix: clean\\n' > stale.txt && git commit -F stale.txt"
precommit "2.6: sudo -iu root bash -lc 'cd failrepo && git commit'" 2 \
  "sudo -iu root bash -lc 'cd @D@/failrepo && git commit -m x'" "$D/work" "FAILING-SUITE-MARKER"
precommit "2.6: cd failrepo || cd passrepo; git commit: no make" 0 \
  'cd @D@/failrepo 2>/dev/null || cd @D@/passrepo; git commit -m x' "$D/work" "" NOMAKE
precommit "2.6: plain git commit in failing cwd" 2 'git commit -m x' "$D/failrepo" "FAILING-SUITE-MARKER"
pair "2.6: ssh host 'bash -s' <<'EOF'" "ssh host 'bash -s' <<'EOF'
git commit -m fix -m \"@T@\"
EOF"
precommit "2.6: flock f su root -c 'cd failrepo && git commit'" 2 \
  "flock @D@/work/lock su root -c 'cd @D@/failrepo && git commit -m x'" "$D/work" "FAILING-SUITE-MARKER"
precommit "2.6: for d in passrepo failrepo; do git -C \"\$d\" commit" 2 \
  'for d in @D@/passrepo @D@/failrepo; do git -C "$d" commit -m x; done' "$D/work" "FAILING-SUITE-MARKER"
precommit "2.6: git -C failrepo commit from another cwd" 2 'git -C @D@/failrepo commit -m x' "$D/work" "FAILING-SUITE-MARKER"
pair "2.6: cd A 2>/dev/null || cd B; cat > m <<EOF; git commit -F m" "cd @D@/nonexistent 2>/dev/null || cd @D@/repo
cat > br-msg26.txt <<'EOF'
fix: thing

@T@
EOF
git commit -F br-msg26.txt"
pair "2.6: flock L -c 'git commit ...'" "flock @D@/work/lock -c 'git commit -m x -m \"@T@\"'"
precommit "2.6: flock L -c 'git -C failrepo commit': no make" 0 \
  "flock @D@/work/lock -c 'git -C @D@/failrepo commit -m x'" "$D/work" "" NOMAKE
PRELOAD=()

echo "---- pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
