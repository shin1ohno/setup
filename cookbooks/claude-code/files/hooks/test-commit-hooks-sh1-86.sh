#!/usr/bin/env bash
# Sourced by test-commit-hooks.sh: commands are payload data, never executed.
# Both hooks run against isolated fixtures; no sudo, su, or real commit runs.

pair "unlisted wrapper explicit shell" "custom-runner -- sh -c 'git -C @D@/repo commit -m \"@T@\"'"
expect_allow "unlisted wrapper quoted printf" "custom-runner -- sh -c 'printf \"git commit Co-Authored-By\"'"
precommit "unlisted wrapper shell failing target" 2 "custom-runner -- sh -c 'git -C @D@/failrepo commit -m x'" "$D/work" "FAILING-SUITE-MARKER"
precommit "unlisted wrapper shell passing target" 0 "custom-runner -- sh -c 'git -C @D@/passrepo commit -m x'" "$D/work"
pair "su login command" "su - fixture -c 'git -C @D@/repo commit -m \"@T@\"'"
pair "su command before account" "su -c 'git -C @D@/repo commit -m \"@T@\"' fixture"
pair "su stdin shell" "su fixture <<'EOF'
git -C @D@/repo commit -m '@T@'
EOF"
pair "runuser explicit command" "runuser -u fixture -- bash -c 'git -C @D@/repo commit -m \"@T@\"'"
pair "runuser su-compatible command" "runuser fixture -c 'git -C @D@/repo commit -m \"@T@\"'"
pair "flock shell" "flock -w 3 @D@/lock bash -c 'git -C @D@/repo commit -m \"@T@\"'"
pair "flock command option" "flock @D@/lock -c 'git -C @D@/repo commit -m \"@T@\"'"
pair "xargs shell" "xargs -I ITEM -P 2 sh -c 'git -C @D@/repo commit -m \"@T@\"'"
pair "find exec shell" "find . -name fixture -exec sh -c 'git -C @D@/repo commit -m \"@T@\"' sh {} \\;"
pair "find execdir shell" "find . -execdir sh -c 'git -C @D@/repo commit -m \"@T@\"' sh {} +"
pair "Linux script command cluster" "script -qec 'git -C @D@/repo commit -m \"@T@\"' /dev/null"
pair "BSD script command" "script -q /dev/null bash -c 'git -C @D@/repo commit -m \"@T@\"'"
pair "sudo stdin shell" "sudo -s <<'EOF'
git -C @D@/repo commit -m '@T@'
EOF"
for cluster in -iu -Hu -Eu; do
  pair "sudo $cluster shell" "sudo $cluster fixture bash -lc 'git -C @D@/repo commit -m \"@T@\"'"
  expect_allow "sudo $cluster data argument" "sudo $cluster fixture printf '%s' 'git commit -m Co-Authored-By'"
  precommit "sudo $cluster failing target" 2 \
    "sudo $cluster fixture bash -lc 'git -C @D@/failrepo commit -m x'" "$D/work" "FAILING-SUITE-MARKER"
done
pair "sudo attached user and cwd" 'sudo -Huuser -D @D@/repo git commit -F @F@'
pair "wrapper preserves quoted variable" "export MSG='@T@'; flock /lock bash -c 'git commit -m \"\$MSG\"'"
for wrapper in 'flock /lock' 'xargs -n 1' 'runuser -u fixture --' 'sudo -Hu fixture' 'script -q /dev/null'; do
  expect_allow "$wrapper data command" "$wrapper printf '%s' 'git commit Co-Authored-By'"
  expect_allow "$wrapper non-commit git" "$wrapper git log --grep='Co-Authored-By'"
done
expect_allow "find data predicate" "find . -name 'git commit Co-Authored-By' -print"
expect_allow "su quoted printf" "su fixture -c 'printf \"git commit Co-Authored-By\"'"
expect_allow "unknown command stays ordinary" "ordinary-tool --label 'bash -c git commit Co-Authored-By'"
expect_allow "xargs value is not shell command" "xargs -I sh printf '%s' 'git commit Co-Authored-By'"
expect_allow "flock option value is not a shell" "flock -E 23 /lock printf '%s' 'git commit Co-Authored-By'"

for wrapper in 'su fixture -c' 'runuser -u fixture -- sh -c' 'flock /lock sh -c' 'xargs -n 1 sh -c' 'script -qc'; do
  precommit "$wrapper failing target" 2 "$wrapper 'git -C @D@/failrepo commit -m x'" "$D/work" "FAILING-SUITE-MARKER"
  precommit "$wrapper passing target" 0 "$wrapper 'git -C @D@/passrepo commit -m x'" "$D/work"
done
precommit "find shell failing target" 2 "find . -exec sh -c 'git -C @D@/failrepo commit -m x' sh {} \;" "$D/work" "FAILING-SUITE-MARKER"
precommit "find shell passing target" 0 "find . -exec sh -c 'git -C @D@/passrepo commit -m x' sh {} \;" "$D/work"

# Guard reachable alternatives; the fallback follows a cd that can fail.
precommit "cd OR first target fails" 2 'cd @D@/failrepo 2>/dev/null || cd @D@/passrepo; git commit -m x' "$D/work" "FAILING-SUITE-MARKER"
precommit "cd OR second target fails" 2 'cd @D@/missing || cd @D@/failrepo; git commit -m x' "$D/work" "FAILING-SUITE-MARKER"
precommit "cd OR both clean" 0 'cd @D@/passrepo || cd @D@/repo; git commit -m x' "$D/work"
precommit "if then target fails" 2 'if test -d @D@/failrepo; then cd @D@/failrepo; else cd @D@/passrepo; fi; git commit -m x' "$D/work" "FAILING-SUITE-MARKER"
precommit "if else target fails" 2 'if test -d @D@/passrepo; then cd @D@/passrepo; else cd @D@/failrepo; fi; git commit -m x' "$D/work" "FAILING-SUITE-MARKER"
precommit "if both clean" 0 'if test -d @D@/passrepo; then cd @D@/passrepo; else cd @D@/repo; fi; git commit -m x' "$D/work"
pair "conditional cwd file source" 'cd @D@/repo || cd @D@/home; git commit -F @F@'

# A Rust marker exercises the real hook runner selection with a fake cargo.
# Never build a user's workspace; fail if the fake runner is not selected.
mkdir -p "$D/rustfail" "$D/rustpass"
printf '[package]\nname="fixture"\nversion="0.0.0"\n' > "$D/rustfail/Cargo.toml"
cp "$D/rustfail/Cargo.toml" "$D/rustpass/Cargo.toml"
cat > "$D/bin/cargo" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$TMPDIR/cargo.log"
case "$PWD" in */rustfail) echo FAILING-RUST-SUITE-MARKER; exit 1 ;; esac
exit 0
EOF
cat > "$D/bin/git" <<'EOF'
#!/usr/bin/env bash
echo 'ERROR: command payload must never execute git' >&2
exit 97
EOF
chmod +x "$D/bin/cargo" "$D/bin/git"
precommit "flock Rust failure uses fake cargo" 2 "flock /lock sh -c 'git -C @D@/rustfail commit -m x'" "$D/work" "FAILING-RUST-SUITE-MARKER"
precommit "flock Rust clean uses fake cargo" 0 "flock /lock sh -c 'git -C @D@/rustpass commit -m x'" "$D/work"
precommit "su Rust failure uses fake cargo" 2 "su fixture -c 'git -C @D@/rustfail commit -m x'" "$D/work" "FAILING-RUST-SUITE-MARKER"
precommit "cd OR Rust failure uses fake cargo" 2 'cd @D@/rustfail || cd @D@/rustpass; git commit -m x' "$D/work" "FAILING-RUST-SUITE-MARKER"
