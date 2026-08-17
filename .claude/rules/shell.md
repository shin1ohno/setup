---
globs: ["*.sh", "*.zsh", "*.bash"]
---

# Shell Script Guidelines

This file is the always-loaded summary. Long examples + origin notes are in `~/.claude/docs/shell-detail.md` (NOT auto-imported — load on demand via Read tool when a section pointer matches the current task).

## Locality Check Before Assuming Remote

Before writing any command that assumes a target host is remote (ssh, scp, rsync over ssh, `gh api` to a remote server, any "please run this on $host" handoff), verify whether the current machine **is** that host. Cheapest possible check:

```
hostname -s
```

If the output matches the target, drop the ssh wrapper and run the command directly.

Rule: whenever a user message mentions a host by name (`pro`, `air`, `$service.home.local`, etc.), if the command you're about to issue depends on that host being remote, `hostname -s` check first. This check is also free to run as part of any "deploy this" or "restart the service on $host" workflow.

Origin: 2026-04-23 weave — ssh'd to a host the session already ran on.

## SSH Reachability Probe Before Delegating or Claiming "No Key"

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

## Bash Tool Runs in the User's Login zsh (darwin) — bash/Linux idiom traps

The Claude Code Bash tool executes through the user's **login zsh** on darwin, not bash. bash/Linux one-liners that look correct fail in zsh-specific ways that are invisible to `bash -n` and usually surface as a *silent* wrong result, not an error. Five recurring traps:

1. **Unquoted `$var` is NOT word-split.** `for r in $REGIONS; do …` iterates ONCE over the whole string — zsh does not field-split unquoted parameters (the opposite of bash). Enumerate elements literally, use an array, or wrap the loop in `/bin/bash -c '…'`.
2. **Unmatched glob aborts the whole script.** zsh `nomatch` makes an unmatched `*.foo` a hard error that kills a multi-line script mid-run — earlier loop output is discarded with it. Quote globs you don't want expanded, or run under bash.
3. **zsh builtins shadow `/usr/bin` commands.** `log …` hits the zsh `log` builtin (`too many arguments`), not `/usr/bin/log`. Verify with `type <cmd>`; call the full path (`/usr/bin/log show …`) when a builtin shadows the binary you meant.
4. **A broken `.zshrc` compdef makes `aws` silently exit 1** (git/gh/curl unaffected). Wrap `aws` in `/bin/bash -c '…'` — see memory `aws-cli-needs-bash-c-wrapper`.
5. **Inline `!` via the Bash tool can arrive mangled to `\!`** — not just jq `!=`; the 2026-06 window also corrupted a `reject!` / `!==` inside a quoted heredoc and a `printf` single-quote `<!--` written to a file (version-dependent) — see the `zsh / harness ! mangling` section below.

**Default policy**: write any command containing a loop, a glob, or multi-line structure as `/bin/bash -c '…'` or `bash -s <<'EOF' … EOF` from the start. Observing ONE zsh-dialect error is the signal to switch the whole command to bash — do not patch it token by token. Note: `/bin/bash -c` / quoted-heredoc wrapping is a fix for traps #1-#3 and does NOT help #5 (`!` corruption) — the corruption has occurred at the harness layer, before the shell; the reliable avoidance for a literal/script containing `!` is to place it with the Write/Edit tool.

**Verification discipline**: before reporting "0 results", drop `2>/dev/null` and re-run one representative case bare to confirm no zsh error was hidden (general form: `~/.claude/rules/debugging.md` Silent Failure Detection). A command that succeeds once but fails inside a loop → suspect the word-split trap (#1) before any external cause. Inline diagnostic one-liners are also subject to the macOS external-command audit (`timeout` / `flock` → exit 127; see below), not just cookbook-distributed scripts. This 0-results re-check is the zsh-error-specific special case — the general gate for asserting absence is CLAUDE.md's `Negative search is not evidence of absence`.

**Multi-file `grep -h` drops the filename — never attribute its lines**: `grep -h -m1 PATTERN file1 file2 file3` prints one match per file with no filename, so reading the output top-to-bottom silently attributes file2's line to file1. When comparing the same field across files (an identifier, a version, a URL), use `-H`, or loop per file (`for f in …; do printf '%s :: %s\n' "$f" "$(grep -m1 … "$f")"; done`), or `rg` (filenames by default). Applies to any claim of the form "file X has the wrong value" — re-probe that single file before reporting a defect. Origin: 2026-07-27 — a `grep -h` sweep over three wiki pages produced a false "wrong PMID in page A" finding that a single-file re-probe disproved and forced a retraction.

Origin: 2026-07-04 — `$REGIONS` / `$repos` word-split misdiagnosed as throttling / reported a false "0"; `log` builtin `too many arguments`; `timeout` exit 127.

## Never Chain Two `sudo` Calls in a `!` Block

When presenting a `!` command for the user to run, do NOT chain two separate `sudo` invocations with `&&`. The first `sudo` succeeds with password entry; the second may re-prompt (timestamp cache not propagated through the chain in the user's shell) or silently skip in the buffered terminal output — the user sees only the first success and assumes the chain completed. Split into numbered `!` items the user runs sequentially, each with its own clean prompt and visible result.

This does NOT apply to:

- A single `sudo` followed by non-sudo verification commands (`sudo X && verify_y` is fine, the verify inherits no password requirement)
- A single `sudo bash -c "..."` that internally chains multiple privileged operations (one password entry, one process)
- The "compose verify with fix" pattern from `~/.claude/rules/debugging.md` — which explicitly chains a fix with a verify, not two privileged operations

Detail (anti-pattern worked example + origin): see `~/.claude/docs/shell-detail.md#chain-two-sudo`.

## SSH inside `while-read` Loop Drains Parent Stdin

`ssh` reads from stdin by default. When invoked inside a `while read VAR; do ...; done < <(jq ...)` (or any process-substitution-fed read loop), `ssh` consumes pending lines from the pipe **before the next iteration's `read` can see them** — the loop exits silently after the first iteration with no error message. Pass `ssh -n` (or `< /dev/null`) so ssh's stdin goes to /dev/null and the parent pipe stays intact. **Same trap applies to** any stdin-reading command in a process-substitution loop: `gpg`, `bash -s`, `read` itself — redirect `< /dev/null` when in doubt.

**Diagnosis signal**: a host loop that should iterate N hosts processes only the first one, exits 0, and emits no parse error. `bash -x` trace shows iteration 2's `read VAR` returning EOF immediately followed by post-loop code.

**Plan-time review checklist**: if an orchestrator-style script has `while read X; do ...; done < <(...)` AND the loop body invokes `ssh`/`gpg`/`bash -s`, confirm `-n` / `< /dev/null` is present BEFORE shipping — the trap is invisible to `shellcheck` and `bash -n`, surfacing only at runtime as a successful run with missing data.

Detail (WRONG/RIGHT code blocks + origin): see `~/.claude/docs/shell-detail.md#ssh-while-read-drains-stdin`.

## Multi-hop Shell Injection (ssh → pct exec → bash)

A command string sent via `ssh host 'pct exec <vmid> -- bash -c "..."'` traverses **three quoting layers** (local shell → remote ssh shell → container bash). Shell metacharacters — `()`, `$()`, backticks, `!` history expansion, `*` glob — inside the innermost string are interpreted at layer 2 (the remote ssh shell), NOT inside the container, causing silent breakage (e.g. commentary parens `(mitamae binary download)` evaluated as a subshell → `command not found` / `syntax error near unexpected token (`, and the rest of the block silently skipped). The same trap fires for direct (non-nested) `bash -c '...'` too — any `()` inside the single-quoted body (typically commentary parens in `echo === foo (bar) ===`) is parsed as subshell grouping. Default to a single-quoted heredoc piped to `bash -s` (`ssh host "pct exec X -- bash -s" <<'EOF' … EOF`): the `<<'EOF'` delimiter sends the body verbatim with no expansion, and `bash -s` reads the script from stdin character-for-character.

**When to use which**:

- `ssh host 'cmd'` (single quotes) — fine for single-line commands without quotes inside
- `ssh host "pct exec X -- bash -s" <<'EOF' ... EOF` — required for any multi-line script with `()`, heredocs, function definitions, or any shell metacharacter
- `ssh host 'pct exec X -- bash -c "..."'` — only for trivial commands; ban for anything with metacharacters

**Composition gate**: before writing any `bash -c '...'`, `ssh host '...'`, or `ssh host 'pct exec <vmid> -- bash -c/-s ...'`, scan the inner body for `()`, `$()`, backticks, `*`, `!`, `<<`, or quotes nested >1 level deep — **commentary parentheses in `echo` statements count** (e.g. `echo (already paused)`). Any hit → switch to the single-quoted `bash -s` heredoc before sending.

Detail (WRONG/RIGHT worked examples + `bash -c` `()` sub-examples + fix options + origins): see `~/.claude/docs/shell-detail.md#multi-hop-shell-injection`.

## `awk '{print $N}'` cannot survive a single-quoted `bash -c` wrapper — use `cut`

Once a script is committed to `bash -c '…'` (required whenever it needs `set -o pipefail`, which dash rejects), no inner single quotes are available, so an awk program has to be written in double quotes — and then **bash expands awk's `$2` / `$10` as its own positional parameters before awk ever runs**. `$2` becomes empty; `$10` becomes `$1` followed by a literal `0`. Nothing errors: every layer's syntax is valid, only the runtime value is wrong, so the pipeline silently produces empty or shifted output.

```bash
# WRONG — bash eats $2 inside the double-quoted awk program
bash -c 'ssh-keygen -lf "$TMP" | awk "{print \$2}" | sort'

# RIGHT — cut has no $-prefixed field syntax to collide with
bash -c 'ssh-keygen -lf "$TMP" | cut -d" " -f2 | sort'
```

Prefer `cut -d<delim> -f<N>`; for logic `cut` cannot express, ship the program as a `files/*.awk` and call `awk -f`. The same substitution applies to `awk -F: '/^x:/ {print $10}'` → `grep "^x:" | cut -d: -f10`.

**Detection**:

```bash
git grep -nE "bash -c '" cookbooks/ | grep -E 'awk.*\$[0-9]'
```

Detail (why no layer errors + origin): see `~/.claude/docs/shell-detail.md#awk-dollar-bash-positional-collision`.

## Prefer sed/awk over `python3 -c` for inline filesystem edits

When the task is "edit one line of an INI/JSON/YAML file" or "remove a section header", default to `sed`/`awk` (or `jq`/`yq` for JSON/YAML) over `python3 -c "..."`. Two recurring failure modes hit the Python form but not sed:

1. **Multi-line `-c` payload is fragile in chat / prompt presentation**: markdown wrapping / paste rendering frequently adds leading spaces to continuation lines, and Python's significant indentation then surfaces as `IndentationError: unexpected indent` even though the source was valid before paste. sed/awk scripts are statement-per-line with no indentation semantics — wrap-resilient.

2. **`python3 -c` with shell-quoted multi-line is hard to compose verbatim**: avoiding shell-side escape collisions for `'...'` inside `"..."` inside `;`-chained statements gets messy fast. sed/awk's regex-and-action grammar is one shell-quote layer deep.

**When python IS the right tool**: when the edit needs Python-grade parsing (multi-line JSON edit with comments, complex schema migration, anything where regex fragility outweighs paste fragility). In those cases, `python3 < /tmp/script.py` with the script written via Write first — never `python3 -c` inline.

Detail (concrete substitution table + origin): see `~/.claude/docs/shell-detail.md#sed-awk-over-python3`.

## awk Cross-platform Pitfalls (BWK vs gawk)

Detail: see `~/.claude/docs/shell-detail.md#awk-bwk-vs-gawk`.

## macOS External-Command Audit for Ported Linux Scripts

Detail: see `~/.claude/docs/shell-detail.md#macos-external-command-audit`.

## zsh / harness `!` mangling — inline `!` can corrupt (jq `!=` and beyond)

Detail: see `~/.claude/docs/shell-detail.md#zsh-bang-history-expansion`.

## User-run block self-containment — cwd 非依存 + pre-emit scan 拡張

ユーザーの端末で実行させる fenced block / `!` ブロックは、ユーザーの端末状態（cwd・直前ブロックの cd・シェル履歴）に依存せず単体で成立させる:

1. **パスは絶対、または同一ブロック内合成**: 相対パスを使うなら同じブロック内で `cd /abs/path && …` に続ける。cargo は `--manifest-path /abs/Cargo.toml`、git は `git -C /abs/path`（git-commit.md の Claude 側 `git -C` ルールのユーザー実行ブロック版）。セッション中に複数リポを触った場合、ユーザーの端末 cwd は Claude の作業対象リポと一致しない前提で書く。

2. **Pre-emit scan の 2 項目追加**: 既存の scratchpad パス検査・GPG チェーン切断検査（git-commit.md）に加え、emit 直前にブロックを見直す: (a) ブロック内の相対パスが、ブロック自身の cd 先と別のリポ / ディレクトリを指していないか、(b) `</parameter>` 等のツール呼び出しタグ断片が（特に末尾行に）混入していないか。混入 1 つでユーザーの round-trip が丸ごと無駄になる。

3. **タグ断片の検出時の回復**: 自分の出力への `</parameter>` 混入を検出した、またはユーザーの実行失敗報告で判明した場合は、CLAUDE.md「Malformed tool call recovery」と同じ文脈飽和シグナルとして扱う — 同 turn で clean なブロックを再 emit し、セッション内 2 件目以降は /compact を提案（同ルールの発生回数カウントに含める）。

4. **1 行が長すぎる / 連結が深い `!` ブロックは分割する**: `&&` 連結が 4 段以上、または 1 行が目安 200 文字を超えると、ユーザーは貼る前に内容を確認できず、貼り付け時の改行崩れも起きる。番号付きの複数ステップに割るか、内容を Write でスクリプトにしてから `! bash /abs/path/script.sh` の 1 行にする。**対話プロンプト（パスフレーズ・確認）を含む手順は必ず 1 段ずつ**に割る — 途中で失敗しても後段が `&&` で連鎖するため、どの段で落ちたか判別できなくなる。加えて、黙って失敗しうる段の直後には checkpoint コマンドを置き、期待値（`subkey=1` 等）を明記して「期待値でなければ次に進まない」と書く。Origin: 2026-08-01 — 鍵投入手順を 7 段 `&&` 連結の 1 行で出してユーザーから分割を要求され、さらに連結形では途中段の無音失敗（保護付き subkey の drop）が検出できず secret のバージョンを 2 つ無駄にした。

Origin: 2026-06-23 — 別ブロックの cd 前提の相対パス `open target/dashboard_shibuya.html` がユーザー端末 cwd で does-not-exist ×2（実体は sibling リポ側）; 2026-06-27 — `!` ブロック末尾に `</parameter>` が混入したままユーザーが実行しコマンド破壊、1 往復無駄。
