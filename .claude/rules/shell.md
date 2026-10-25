# Shell Script Guidelines

Examples and origins: `~/.claude/docs/shell-detail.md` (on-demand).

## Locality Check Before Assuming Remote

Before any command that assumes a named host (`pro`, `air`, `$service.home.local`) is remote — ssh, scp, rsync, a "run this on $host" handoff — run `hostname -s`; if it matches, drop the ssh wrapper and run directly. Detail: see `~/.claude/docs/shell-detail.md#locality-check`.

## SSH Reachability Probe Before Delegating or Claiming "No Key"

Before presenting `! ssh/scp …`, claiming "no key" / "cannot reach", or designing around an unreachable host: run `ssh -G <host>` + `ssh-keygen -F <host>`, then probe once with `ssh -o ConnectTimeout=5 <host> hostname` (`accept-new` on first contact); a failed `BatchMode` run with hand-picked `-i` keys never proves "鍵がない". `Too many authentication failures` → retry once with `-o IdentitiesOnly=yes -i <key>`. Keep ssh options as literal argv tokens. On failure report the error class (auth / network / host-key), record reachability to project memory, present ONE composed `!` fallback. Detail: see `~/.claude/docs/shell-detail.md#ssh-reachability-probe`.

## Bash Tool Runs in the User's Login zsh (darwin) — bash/Linux idiom traps

zsh silently breaks bash idioms: no word-split of unquoted `$var`, unmatched globs abort, builtins shadow binaries (`/usr/bin/log`), `aws` exits 1 unless wrapped in `/bin/bash -c`, inline `!` may arrive as `\!`. Write loops / globs / multi-line commands as `/bin/bash -c '…'` or `bash -s <<'EOF'` from the start (switch on the first zsh error); place `!`-bearing content with Write/Edit. Before reporting "0 results", re-run one case without `2>/dev/null`; never attribute multi-file `grep -h` lines (use `-H` / `rg`; re-probe the one file before reporting a defect). Detail: see `~/.claude/docs/shell-detail.md#zsh-login-shell-traps`.

## Never Chain Two `sudo` Calls in a `!` Block

Never `&&`-chain two separate `sudo` calls in a user `!` block; split them into numbered `!` items. Allowed: one `sudo` plus non-sudo verification, one `sudo bash -c "…"`, and the fix-plus-verify pattern of `~/.claude/rules/debugging.md`. Detail: see `~/.claude/docs/shell-detail.md#chain-two-sudo`.

## SSH inside `while-read` Loop Drains Parent Stdin

`ssh` (also `gpg`, `bash -s`, `read`) inside `while read …; done < <(…)` eats the loop's stdin: one iteration, exit 0, no error. Use `ssh -n` / `< /dev/null`, and check every such loop before shipping (`shellcheck` misses it). Detail: see `~/.claude/docs/shell-detail.md#ssh-while-read-drains-stdin`.

## Multi-hop Shell Injection (ssh → pct exec → bash)

Before any `bash -c '…'`, `ssh host '…'` or `ssh host 'pct exec <vmid> -- bash -c …'`, scan the body for `()` (commentary parens in `echo` count), `$()`, backticks, `*`, `!`, `<<` or quotes nested >1 deep; any hit → `ssh host "pct exec X -- bash -s" <<'EOF' … EOF`. Plain `ssh host 'cmd'` only for one line without inner quotes. Detail: see `~/.claude/docs/shell-detail.md#multi-hop-shell-injection`.

## `awk '{print $N}'` cannot survive a single-quoted `bash -c` wrapper — use `cut`

In `bash -c '…'` (needed for `pipefail`), a double-quoted awk program has `$2`/`$10` expanded by bash first — silent empty or shifted output. Use `cut -d<delim> -f<N>`, or a `files/*.awk` via `awk -f`. Detection: `git grep -nE "bash -c '" cookbooks/ | grep -E 'awk.*\$[0-9]'`. Detail: see `~/.claude/docs/shell-detail.md#awk-dollar-bash-positional-collision`.

## Prefer sed/awk over `python3 -c` for inline filesystem edits

For one-line INI/JSON/YAML edits, use `sed`/`awk` (`jq`/`yq`) rather than `python3 -c`. When Python-grade parsing is needed, Write the script first and run `python3 < /tmp/script.py`, never `python3 -c` inline. Detail: see `~/.claude/docs/shell-detail.md#sed-awk-over-python3`.

## A `sed` delimiter must not occur in the pattern OR the replacement

A `s#…#…#` / `|` / `@` delimiter must occur on neither side (`#123` refs and URL fragments bring `#`, tables bring `|`); otherwise split the edit, use `$'\x01'`, or a script file. After any scripted edit, `grep` for the new text before staging. Detail: see `~/.claude/docs/shell-detail.md#sed-delimiter-collision`.

## No leading bare `cd` in a command whose exit code or stdout you read

`cd <dir> && cmd` fires the `chpwd` hook, polluting the stdout and exit code you read. Pass the directory to the tool (`-chdir=`, `-C`, `--prefix`, `--manifest-path`, absolute paths) or use `( cd /abs && cmd )` and capture `cmd`'s own exit code, not a trailing `| head`'s. Detail: see `~/.claude/docs/shell-detail.md#no-leading-cd`.

## The Bash tool's `find` is bfs, not GNU findutils

On pro-dev `find` is bfs 4.1.1: GNU-only `-newermt '-120 seconds'` errors to stderr while `find … | wc -l` reads 0 and exits 0. Before a looped `find` probe, confirm a non-zero count on a directory being written; `-mmin -N` works in both. Detail: see `~/.claude/docs/shell-detail.md#find-is-bfs`.

## A denied pattern anywhere in a compound command denies all of it

One deny-matching part refuses the whole chained command: run `rm -rf` (and other deny-listed forms) in its own call or leave untracked scratch. `Bash(rm -rf /tmp/:*)` matches literal text, so `rm -rf "$T"` still hits the `Bash(rm -rf:*)` deny. Detail: see `~/.claude/docs/shell-detail.md#compound-command-deny`.

## awk Cross-platform Pitfalls (BWK vs gawk)

Detail: see `~/.claude/docs/shell-detail.md#awk-bwk-vs-gawk`.

## macOS External-Command Audit for Ported Linux Scripts

Detail: see `~/.claude/docs/shell-detail.md#macos-external-command-audit`.

## zsh / harness `!` mangling — inline `!` can corrupt (jq `!=` and beyond)

Detail: see `~/.claude/docs/shell-detail.md#zsh-bang-history-expansion`.

## User-run block self-containment — cwd 非依存 + pre-emit scan 拡張

ユーザー端末で実行させる block / `!` は cwd に依存させません。(1) パスは絶対か同ブロック内 `cd /abs && …`（cargo は `--manifest-path`、git は `git -C`）。(2) emit 前に、相対パスの指す先と `</parameter>` 等のタグ断片混入を確認します。(3) 混入を検出したら同 turn で clean に再 emit し、2 件目以降は /compact を提案します（CLAUDE.md「Malformed tool call recovery」と同扱い）。(4) `&&` 4 段以上・200 文字超は番号付きか `! bash /abs/script.sh` に分け、対話プロンプトは 1 段ずつ、黙って失敗しうる段の後に期待値付き checkpoint を置きます。Detail: see `~/.claude/docs/shell-detail.md#user-run-block-self-containment`.
