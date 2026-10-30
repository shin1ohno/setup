# Shell Script Guidelines — Examples & Origin Notes

On-demand detail for `~/ManagedProjects/setup/.claude/rules/shell.md`. Read a section when the summary points here.


## awk-bwk-vs-gawk

## awk Cross-platform Pitfalls (BWK vs gawk)

`awk -v VAR=value` looks portable BUT **macOS BWK awk rejects literal newlines inside `-v` values**, while Linux gawk accepts them. CI runs on Linux → bug invisible. mitamae apply on Mac → `awk: newline in string` with exit 2.

Trap (real, 2026-05-11 setup PR #330):

```bash
ES_HOSTS_YAML="    - https://es-0...
    - https://es-1...
    - https://es-2..."

awk -v hosts="${ES_HOSTS_YAML}" '{ ... }'   # OK on Linux gawk, FAILS on macOS BWK
```

**Fixes** (pick by context):

1. **Temp file pattern** (most portable, no escape traps):

```bash
HOSTS_FILE=$(mktemp)
trap 'rm -f "${HOSTS_FILE}"' EXIT
printf '%s\n' "${ES_HOSTS_YAML}" > "${HOSTS_FILE}"
awk -v hosts_file="${HOSTS_FILE}" '
{
    if ($0 ~ /@@MARKER@@/) {
        while ((getline line < hosts_file) > 0) print line
        close(hosts_file)
    } else { print }
}' "$TEMPLATE"
```

2. **stdin via pipe** (when the value IS the awk input):

```bash
printf '%s\n' "${MULTI_LINE}" | awk '{ ... }'
```

3. **Replace newlines with a sentinel + split inside awk** (when the value is one of several `-v` inputs):

```bash
awk -v hosts="$(printf '%s' "${MULTI_LINE}" | tr '\n' '\036')" \
    'BEGIN { n = split(hosts, a, "\036") } { ... }'
```

Default to the **temp file pattern**. Other approaches accumulate escape complexity. `-v` values with a single embedded newline can sometimes pass on Mac too — do not rely on this; treat any multi-line `-v` value as unsupported.

**Plan-time detection**: any cookbook with a multi-line shell variable feeding `awk -v` must be tested with macOS BWK awk before merge. `bash -n` does not catch this; the failure surfaces only at runtime under mac awk. CI on Linux gawk is also blind to it.

Origin: 2026-05-11 PR #330 — multi-line `awk -v` passed Linux CI, failed macOS BWK with `awk: newline in string`. Fix: temp file pattern in `cookbooks/elastic-agent/files/generate_config.sh`.

## macos-external-command-audit

## macOS External-Command Audit for Ported Linux Scripts

`bash -n`, `ruby -c`, and `mitamae --dry-run` check syntax and resource placement only — they do NOT verify that external commands exist on the target OS. A script using a Linux-only command passes all static checks and misfires silently at runtime.

**Trigger**: any shell script deployed by a cookbook that runs on macOS (`darwin.rb`, any `air` / `ohnos-macbook` role) that was written or tested on Linux.

Before shipping, grep the script for Linux-only commands:

```bash
grep -E '\b(flock|timeout|gtimeout|sponge|tac|nproc|numfmt|realpath|readlink)\b' <script>
```

**Silent-failure trap for `flock`**: `if ! flock …` reads exit 127 (command not found) as truthy → the script logs "another run holds the lock" and silently skips. This is NOT an error; it is a false skip that persists every run (looks like normal lock contention).

macOS-native replacements:

- `flock` → `mkdir` + PID lock: `if ! mkdir "$LOCKDIR" 2>/dev/null; then exit 0; fi; trap 'rm -rf "$LOCKDIR"' EXIT; echo $$ > "$LOCKDIR/pid"` (stale lock: `kill -0` the recorded PID, steal only if the holder is dead)
- `timeout N cmd` → background watchdog: `cmd & PID=$!; (sleep N; kill -TERM $PID 2>/dev/null) & wait $PID`
- `realpath` / `readlink -f` → `$(cd "$(dirname "$f")"; pwd)/$(basename "$f")`

Static check alone is insufficient — run the script once on the target OS before declaring the cookbook done.

Origin: 2026-06-27 zp-SHIN issue/PR loop (mercari-setup overlay) — `flock` / `timeout` absent on macOS; `if ! flock` silently misfired as "lock held" every run; passed `bash -n` + `mitamae --dry-run`, surfaced only at runtime on `air`.

## zsh-bang-history-expansion

## zsh / harness `!` mangling — inline `!` can corrupt (jq `!=` and beyond)

An inline `!` passed through the Claude Code Bash tool can arrive mangled to `\!`. This is NOT limited to the jq `!=` operator: in the 2026-06 window the same class fired 3 times across 2 repos — (i) setup 2026-06-12, a `reject!` Ruby method inside a single-quoted heredoc body was corrupted; (ii) zp-SHIN 2026-06-16, a JS `!==` inside a heredoc was corrupted; (iii) zp-SHIN 2026-06-27, `printf '%s\n' '<!-- ... -->' >> file` silently wrote `<\!--` into the file (no error; the corruption survived into the committed artifact).

**Mechanism (corrected)**: the command shown in the transcript is clean and only the *executed result* carries the `\!` — so this is NOT zsh history expansion (which is inert inside single quotes). It is a `!`-escape at the harness layer, BEFORE the string reaches any shell. Therefore quote form, a `/bin/bash -c` wrapper, and a single-quoted heredoc do NOT prevent it — all of those live below the harness layer.

**Current status (keep this note fresh)**: a 2026-07-06 probe reproduced NONE of the above (the 3 shapes + jq `!=`) — likely a harness fix. So this is a version-dependent known class, NOT an always-breaks rule; do NOT mechanically ban inline `!`.

**jq case (still the most common trigger)**: when TEST-ing a jq filter interactively via the Bash tool, prefer the `| not` form over `!=` / bare `!`:

- `.field != "value"` → `(.field == "value" | not)`
- any `select(... != ...)` held in a shell var → phrase the negation with `| not`

The deployed script (bash, no history expansion) runs the original `!=` filter fine, so `| not` mainly makes the interactive test match the runtime.

**Detection recipe**: right after writing `!`-containing content through the shell, byte-verify with `od -c <file>` or `grep -n '\\!' <file>` before committing. If you observe `\!`, switch to the Write/Edit tool to place the literal/script (all 3 sessions recovered via Write/Edit).

Origin: 2026-06-28 zp-issue-loops merge-gate — `JQ='... (.mergeStateStatus != "CLEAN") ...'` mangled to `\!=` in the Bash tool while the launchd runner ran the identical filter cleanly; rephrased as `(.mergeStateStatus == "CLEAN" | not)`. Extended 2026-06 by the 3 heredoc/printf cases above. The candidate claim that a loop-body shell negation `! rg -q …` also corrupts is NOT included — no evidence, not reproduced.

## chain-two-sudo

## Never Chain Two `sudo` Calls in a `!` Block

```
# Anti-pattern — second sudo silently doesn't run if its prompt isn't visible
! sudo dpkg-divert --rename --add /usr/sbin/resolvconf && sudo systemctl restart tailscaled
```

The first `sudo` succeeds with password entry. The second `sudo` may either re-prompt (because the timestamp cache wasn't propagated through the chain in the user's shell) or appear to skip silently in the buffered terminal output. Either way, the user often sees only the first command's success message and assumes the chain completed. Diagnosing the silent skip costs a round-trip.

Instead, split into numbered `!` items the user runs sequentially:

```
1. ! sudo dpkg-divert --rename --add /usr/sbin/resolvconf
2. ! sudo systemctl restart tailscaled
```

Each gets its own clean prompt and visible result. The user can re-run any step in isolation if needed.

Origin: 2026-04-26 — chained `sudo ... && sudo ...` `!` block, second sudo silently skipped.

## ssh-while-read-drains-stdin

## SSH inside `while-read` Loop Drains Parent Stdin

**Wrong** (consumes pipe — silently skips host #2 onward):

```bash
while IFS= read -r entry; do
    host=$(jq -r '.host' <<<"$entry")
    output=$(ssh -i key root@"$host" "$cmd")  # ← reads parent stdin, drains pipe
    ...
done < <(jq -c '.[]' "$HOSTS_JSON")
```

**Right** — pass `-n` (or `< /dev/null`) so ssh's stdin goes to /dev/null and the parent pipe stays intact:

```bash
while IFS= read -r entry; do
    host=$(jq -r '.host' <<<"$entry")
    output=$(ssh -n -i key root@"$host" "$cmd")
    ...
done < <(jq -c '.[]' "$HOSTS_JSON")
```

`ssh` consumes pending lines from the pipe **before the next iteration's `read` can see them**. **Same trap applies to** any stdin-reading command in a process-substitution loop: `gpg`, `bash -s`, `read` itself — redirect `< /dev/null` when in doubt.

**Diagnosis signal**: a host loop that should iterate N hosts processes only the first one, exits 0, and emits no parse error. `bash -x` trace shows iteration 2's `read VAR` returning EOF immediately followed by post-loop code.

**Plan-time review checklist**: if an orchestrator-style script has `while read X; do ...; done < <(...)` AND the loop body invokes `ssh`/`gpg`/`bash -s`, confirm `-n` / `< /dev/null` is present BEFORE shipping — the trap is invisible to `shellcheck` and `bash -n`, surfacing only at runtime as a successful run with missing data.

Origin: 2026-05-06 PR #153 — bare ssh in jq-fed read loop dropped all hosts but the first.

## multi-hop-shell-injection

## Multi-hop Shell Injection (ssh → pct exec → bash)

When running commands inside a PVE LXC via `ssh host 'pct exec <vmid> -- bash -c "..."'`, the command string traverses **three quoting layers** before reaching the inner bash:

1. The local shell (this machine) interprets the outer single quotes
2. The remote ssh shell (PVE host) interprets `pct exec ... -- bash -c "..."` — the `bash -c` argument is the double-quoted string
3. The container's bash (CT) executes the contents of the double-quoted string

Shell metacharacters — `()`, `$()`, backticks, `!` history expansion, `*` glob — inside the innermost string are interpreted at layer 2 (the remote ssh shell), NOT inside the container. This causes silent breakage:

```
ssh root@pve.host 'pct exec 111 -- bash -c "
  echo '===' step 1.3: bin/setup (mitamae binary download) ===
  ...
"'
# Layer 2 evaluates `(mitamae binary download)` as a subshell call to
# the command `mitamae`, fails with `mitamae: command not found` (or
# `syntax error near unexpected token (` when nested) — and the rest
# of the multi-line block silently doesn't run.
```

**Clean pattern — single-quoted heredoc piped to `bash -s`**:

```
ssh root@pve.host "pct exec 111 -- bash -s" <<'EOF'
set -euo pipefail
echo '===' step 1.3: bin/setup (mitamae binary download) ===
cd /root/setup && ./bin/setup
EOF
```

Why this works:

- The outer `"..."` only wraps the ssh command-line — no metacharacter interpretation inside the command body
- `<<'EOF'` (single-quoted delimiter) tells the local shell to send the heredoc content **verbatim** with no expansion of `$VAR`, `$()`, `()`, backticks, or `!`
- `bash -s` reads from stdin (the heredoc) instead of taking a `-c` argument, so the inner bash sees the script source character-for-character

**Same trap fires for direct (non-nested) `bash -c '...'` too**: any `()` inside the single-quoted body — typically commentary parentheses in `echo '===' foo (bar) ===` — is interpreted as subshell grouping by the inner bash. Both forms break:

```
bash -c 'echo '===' foo (bar) ==='
# bash: -c: line 1: syntax error near unexpected token '('

ssh host 'echo '===' foo (bar) ==='
# Same error at the remote shell, before reaching anything else
```

Fix options (any work):

- Drop the parens: `echo '===' foo bar ===`
- Escape: `echo "=== foo (bar) ==="` (use double quotes outside, or escape `\(\)`)
- Heredoc: `bash <<'EOF' ... EOF` (no -c argument)

**When to use which**:

- `ssh host 'cmd'` (single quotes) — fine for single-line commands without quotes inside
- `ssh host "pct exec X -- bash -s" <<'EOF' ... EOF` — required for any multi-line script with `()`, heredocs, function definitions, or any shell metacharacter
- `ssh host 'pct exec X -- bash -c "..."'` — only for trivial commands; ban for anything with metacharacters

**Composition gate**: before writing any `bash -c '...'`, `ssh host '...'`, or `ssh host 'pct exec <vmid> -- bash -c/-s ...'`, scan the inner body for `()`, `$()`, backticks, `*`, `!`, `<<`, or quotes nested >1 level deep — **commentary parentheses in `echo` statements count** (e.g. `echo (already paused)`). Any hit → switch to the single-quoted `bash -s` heredoc before sending.

Origin: 2026-05-06 / 2026-05-11 / 2026-06-07 — `syntax error near unexpected token '('` from commentary parens in `echo '===' ... ===` headers through three remote shells; structural, recurs per metacharacter unless heredoc + `bash -s` is the default.

## awk-dollar-bash-positional-collision

## `awk $N` vs bash positional parameters inside a quoted `bash -c`

The failing shape: a script is already committed to `bash -c '…'` — most often because it needs `set -euo pipefail`, which dash rejects as a bare mitamae `command` (see the pipefail rule in `~/ManagedProjects/setup/.claude/rules/ruby.md` / the `bash -c` wraps in `cookbooks/{codex-cli,mcp,herdr,terraform}`). Single quotes are therefore unavailable inside, so an awk program gets written in double quotes:

```bash
bash -c 'ssh-keygen -lf "$TMP" | awk "{print \$2}" | sort'
```

Bash parses `$2` as its own positional parameter and substitutes empty **before awk is invoked**, so awk receives `{print }`. `$10` degrades differently — `$1` followed by a literal `0`.

**Why nothing catches it**: `ruby -c`, `bash -n`, `mitamae --dry-run`, and the outer shell's own parse all pass, because every layer's syntax IS valid. Only the runtime value is wrong, and the pipeline still exits 0. It surfaces as an empty or shifted field downstream — e.g. a fingerprint comparison that always mismatches, or a variable that is silently blank.

`cut` sidesteps the class entirely (no `$`-prefixed field syntax):

```bash
cut -d' ' -f2
grep "^fpr:" | cut -d: -f10   # replaces awk -F: '/^fpr:/ {print $10}'
```

For logic `cut` cannot express, ship the program as `files/<name>.awk` via `remote_file` and invoke `awk -f`, removing inline quoting from the problem entirely.

Origin: 2026-08-01 sh1-cloud `gcp-ssh-keys` cookbook (zp-SHIN #111) — a github.com `known_hosts` keyscan needed field 2 of `ssh-keygen -lf` output for fingerprint verification, inside a `bash -c` wrapper the `set -euo pipefail` forced. Caught by rendering the cookbook through a stub DSL and executing the extracted script, not by any syntax check.

## sed-awk-over-python3

## Prefer sed/awk over `python3 -c` for inline filesystem edits

Applies when the task is "edit one line of an INI/JSON/YAML file" or "remove a section header". Two recurring failure modes hit the Python form but not sed:

1. **Multi-line `-c` payload is fragile in chat / prompt presentation**: markdown wrapping / paste rendering frequently adds leading spaces to continuation lines, and Python's significant indentation then surfaces as `IndentationError: unexpected indent` even though the source was valid before paste. sed/awk scripts are statement-per-line with no indentation semantics — wrap-resilient.
2. **`python3 -c` with shell-quoted multi-line is hard to compose verbatim**: avoiding shell-side escape collisions for `'...'` inside `"..."` inside `;`-chained statements gets messy fast. sed/awk's regex-and-action grammar is one shell-quote layer deep.

**When python IS the right tool**: when the edit needs Python-grade parsing (multi-line JSON edit with comments, complex schema migration, anything where regex fragility outweighs paste fragility).

**Concrete substitutions**:

| Task | python3 -c (avoid) | sed/awk (prefer) |
|---|---|---|
| Remove INI section `[name]` and its body | `python3 -c "import configparser; c=configparser.ConfigParser(); c.read('f'); c.remove_section('name') if 'name' in c else None; c.write(open('f','w'))"` | `sed -i.bak '/^\[name\]$/,/^\[/{/^\[name\]$/d; /^\[/!d}' f` |
| Replace value of `key = ...` in INI | `python3 -c "..."` (multi-line) | `sed -i 's/^key = .*/key = newvalue/' f` |
| Filter JSON one key | (Python possible) | `jq '.key' f` (preferred over either) |
| Edit YAML | (Python possible) | `yq` if available, else sed for simple cases |

Origin: 2026-05-11 — multi-line `python3 -c` paste-broke with `IndentationError`; one sed command worked first try.

## locality-check

Cheapest possible check before writing any command that assumes a target host is remote (ssh, scp, rsync over ssh, `gh api` to a remote server, any "please run this on $host" handoff):

```
hostname -s
```

If the output matches the target, drop the ssh wrapper and run the command directly. Whenever a user message mentions a host by name (`pro`, `air`, `$service.home.local`, etc.) and the command you're about to issue depends on that host being remote, run this check first. It is also free to run as part of any "deploy this" or "restart the service on $host" workflow.

Origin: 2026-04-23 weave — ssh'd to a host the session already ran on.

## ssh-reachability-probe

Trigger: you are about to (a) frame a step as "please run this on <host>" / present `! ssh/scp ...`, (b) claim "no key for <host>" / "this shell cannot reach <host>", or (c) design a flow around <host> being unreachable.

1. **Resolve what plain ssh would actually do — zero network, 1 second**:
   ```bash
   ssh -G <host> | grep -iE '^(hostname|user|identityfile) '  # effective config incl. ~/.ssh/config aliases
   ssh-keygen -F <host>                                        # known_hosts registration (first-contact check)
   ```
   `ssh -G` shows the IdentityFile plain ssh will use; it supersedes guessing from `ls ~/.ssh`.

2. **Probe once**, letting the user's config + agent work, with hang guards only:
   ```bash
   ssh -o ConnectTimeout=5 <host> hostname
   ```
   Add `-o StrictHostKeyChecking=accept-new` for a first-contact host. A failed `-o BatchMode=yes` run with hand-enumerated `-i` keys proves "these keys failed" — NEVER "no credential exists". Do not claim "鍵がない" from it.

3. **`Too many authentication failures`** (server disconnects mid-auth) = the agent/config offered too many keys, not a missing key. Retry once with `-o IdentitiesOnly=yes -i ~/.ssh/<host>_ed25519` (key path from step 1).

4. **Write ssh options as literal argv tokens.** `KEY="-i ~/.ssh/x"; ssh $KEY host` makes ssh parse the whole string as one token (`hostname contains invalid characters`). Never pack option+path into one shell variable.

5. **Probe failed → report the exact error class** (auth vs network vs host-key), record the host reachability map to project memory (cf. `session-shell-ssh-access`), and present the fallback as ONE composed `! ssh/scp ...` command — not a sequence of retries for the user.

Origin: 2026-07-04 ×2 — three delegations + a "鍵がない" claim the user disproved with plain ssh/scp; a separate session's 5 ssh attempts (incl. Too-many-auth-failures + the `-i`-in-variable token bug) all compressible to one step-1+2 probe.

## zsh-login-shell-traps

The Claude Code Bash tool executes through the user's **login zsh** on darwin, not bash. bash/Linux one-liners that look correct fail in zsh-specific ways that are invisible to `bash -n` and usually surface as a *silent* wrong result, not an error:

1. **Unquoted `$var` is NOT word-split.** `for r in $REGIONS; do …` iterates ONCE over the whole string — zsh does not field-split unquoted parameters (the opposite of bash). Enumerate elements literally, use an array, or wrap the loop in `/bin/bash -c '…'`.
2. **Unmatched glob aborts the whole script.** zsh `nomatch` makes an unmatched `*.foo` a hard error that kills a multi-line script mid-run — earlier loop output is discarded with it. Quote globs you don't want expanded, or run under bash.
3. **zsh builtins shadow `/usr/bin` commands.** `log …` hits the zsh `log` builtin (`too many arguments`), not `/usr/bin/log`. Verify with `type <cmd>`; call the full path (`/usr/bin/log show …`) when a builtin shadows the binary you meant.
4. **A broken `.zshrc` compdef makes `aws` silently exit 1** (git/gh/curl unaffected). Wrap `aws` in `/bin/bash -c '…'` — see memory `aws-cli-needs-bash-c-wrapper`.
5. **Inline `!` via the Bash tool can arrive mangled to `\!`** — not just jq `!=`; the 2026-06 window also corrupted a `reject!` / `!==` inside a quoted heredoc and a `printf` single-quote `<!--` written to a file (version-dependent) — see `#zsh-bang-history-expansion`.
6. **A bare word starting with `=` is command-path expanded.** `echo '==='` fails the whole line with `== not found` (zsh `=cmd` expansion) and aborts a compound command with it. Quote separators: `echo '==='` or `printf '%s\n' '=== label'`. Observed 2026-10-30 on sh1-cloud (Linux) — the traps in this section are not darwin-only.
7. **`mapfile` / `readarray` are bash builtins, absent in zsh** (`command not found: mapfile`). Put array-loading scripts in a file and run `bash file.sh`, or in zsh use `arr=("${(@f)$(cmd)}")`.

**Default policy**: observing ONE zsh-dialect error is the signal to switch the whole command to bash — do not patch it token by token. `/bin/bash -c` / quoted-heredoc wrapping fixes traps #1-#3 and does NOT help #5: the corruption happens at the harness layer, before the shell, so the reliable avoidance for a literal/script containing `!` is to place it with the Write/Edit tool.

**Verification discipline**: the "0 results" re-check (drop `2>/dev/null`, re-run one representative case bare) is the zsh-error-specific case of `~/.claude/rules/debugging.md` Silent Failure Detection; the general gate for asserting absence is `Negative search is not evidence of absence` in the shared AGENTS.md. A command that succeeds once but fails inside a loop → suspect the word-split trap (#1) before any external cause. Inline diagnostic one-liners are also subject to the macOS external-command audit (`timeout` / `flock` → exit 127; `#macos-external-command-audit`), not just cookbook-distributed scripts.

**Multi-file `grep -h` drops the filename**: `grep -h -m1 PATTERN file1 file2 file3` prints one match per file with no filename, so reading the output top-to-bottom silently attributes file2's line to file1. When comparing the same field across files (an identifier, a version, a URL), use `-H`, or loop per file (`for f in …; do printf '%s :: %s\n' "$f" "$(grep -m1 … "$f")"; done`), or `rg` (filenames by default). Applies to any claim of the form "file X has the wrong value". Origin: 2026-07-27 — a `grep -h` sweep over three wiki pages produced a false "wrong PMID in page A" finding that a single-file re-probe disproved and forced a retraction.

Origin: 2026-07-04 — `$REGIONS` / `$repos` word-split misdiagnosed as throttling / reported a false "0"; `log` builtin `too many arguments`; `timeout` exit 127.

## sed-delimiter-collision

Switching `s/…/…/` to `s#…#…#` (or `|`, `@`) to dodge slashes in a path only works if the new delimiter appears in neither side. Scan the **replacement** text too: GitHub references (`#123`), URL fragments and shell comments bring `#` in; a pipe-separated table brings `|`. The failure is `unknown option to 's'` — or, worse, a silently truncated substitution when the stray delimiter lands where a flag is legal. When the replacement's character set is not under your control, split the edit, pick a delimiter that cannot occur (a control character via `$'\x01'`), or write the edit as a small script file. A failed `sed` inside a chain leaves the file untouched and the next `git add` commits the old content — hence the grep-before-staging step.

Origin: 2026-09-26 — `s#…#…#` with a replacement containing a PR reference like `#123456` failed and the unmodified file was committed, then amended.

## no-leading-cd

`cd <dir> && cmd` runs the login shell's `chpwd` hook (an auto-`tree` / `ls` on these machines) between the two, so its output lands in the stdout you are about to parse and `$?` of a trailing pipeline no longer means what you think. This is the general form of the git-specific rule in `~/.claude/rules/git-commit.md` ("Never use `cd` to set git context") and the search-specific one (Negative search, now in the shared `~/.agents/AGENTS.md` Probe Discipline; the summary formerly cited `~/.claude/rules/ask-user-question.md`): it applies to every command whose result you read — a formatter's `-check`, a test runner, a validator, a count.

Origin: 2026-09-26 — `cd /tmp && terraform fmt -check … | head; echo $?` printed a full `/tmp` tree and reported `head`'s exit code; the check had to be rerun with `-chdir`.

## find-is-bfs

On pro-dev the Bash tool's `find` is a shell function from the zsh shell snapshot that runs bfs 4.1.1 (`type find`). GNU-only spellings are an error there, not a no-match: the message goes to stderr, and a pipeline that counts the output still reads 0 and exits 0. A liveness or stall watcher built that way reports "no activity" on every pass while its target is busy.

Origin: 2026-09-28 agent-pilot — a review-workflow watcher reported "STALL: no activity for 10 min" while seven agent transcripts were being written.

## compound-command-deny

The permission layer refuses a whole multi-line or `&&`-chained Bash command when any part of it matches a deny rule, so a command that does useful work and then cleans up with `rm -rf` loses the useful part too. The allow rule `Bash(rm -rf /tmp/:*)` in `~/.claude/settings.json` matches the literal command text: `rm -rf "$T"` with `$T` under /tmp still falls to the `Bash(rm -rf:*)` deny, so write the literal path when you rely on it.

Origin: 2026-09-27/28 agent-pilot — three compound commands (a `gh aw compile` run, a sandbox dry-run setup, a sandbox sync) were refused for their cleanup step and had to be rebuilt.

## user-run-block-self-containment

ユーザーの端末で実行させる fenced block / `!` ブロックは、ユーザーの端末状態（cwd・直前ブロックの cd・シェル履歴）に依存せず単体で成立させます。

1. **パスは絶対、または同一ブロック内合成**: 相対パスを使うなら同じブロック内で `cd /abs/path && …` に続けます。cargo は `--manifest-path /abs/Cargo.toml`、git は `git -C /abs/path`（git-commit.md の Claude 側 `git -C` ルールのユーザー実行ブロック版）。セッション中に複数リポを触った場合、ユーザーの端末 cwd は Claude の作業対象リポと一致しない前提で書きます。
2. **Pre-emit scan の 2 項目追加**: 既存の scratchpad パス検査・GPG チェーン切断検査（git-commit.md）に加え、emit 直前にブロックを見直します: (a) ブロック内の相対パスが、ブロック自身の cd 先と別のリポ / ディレクトリを指していないか、(b) `</parameter>` 等のツール呼び出しタグ断片が（特に末尾行に）混入していないか。混入 1 つでユーザーの round-trip が丸ごと無駄になります。
3. **タグ断片の検出時の回復**: 自分の出力への `</parameter>` 混入を検出した、またはユーザーの実行失敗報告で判明した場合は、CLAUDE.md「Malformed tool call recovery」と同じ文脈飽和シグナルとして扱います（同ルールの発生回数カウントに含める）。
4. **1 行が長すぎる / 連結が深い `!` ブロックは分割する**: `&&` 連結が 4 段以上、または 1 行が目安 200 文字を超えると、ユーザーは貼る前に内容を確認できず、貼り付け時の改行崩れも起きます。内容を Write でスクリプトにしてから `! bash /abs/path/script.sh` の 1 行にする方法もあります。対話プロンプト（パスフレーズ・確認）を含む手順を 1 段ずつに割るのは、途中で失敗しても後段が `&&` で連鎖し、どの段で落ちたか判別できなくなるためです。checkpoint には期待値（`subkey=1` 等）を明記し、「期待値でなければ次に進まない」と書きます。Origin: 2026-08-01 — 鍵投入手順を 7 段 `&&` 連結の 1 行で出してユーザーから分割を要求され、さらに連結形では途中段の無音失敗（保護付き subkey の drop）が検出できず secret のバージョンを 2 つ無駄にした。

Origin: 2026-06-23 — 別ブロックの cd 前提の相対パス `open target/dashboard_shibuya.html` がユーザー端末 cwd で does-not-exist ×2（実体は sibling リポ側）; 2026-06-27 — `!` ブロック末尾に `</parameter>` が混入したままユーザーが実行しコマンド破壊、1 往復無駄。
