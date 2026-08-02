# Negative Search Is Not Evidence of Absence — Detail

Load when you are about to assert "not found / zero references / unsupported".

The always-loaded summary (positive control, `git grep` / `git ls-files` cross-check, no leading `cd`) is the CLAUDE.md bullet `Negative search is not evidence of absence`. This file holds the three per-case gotchas that generalize it.

## Template mechanisms hide hostname / URL literals

A literal `grep` / `rg` for a hostname, IP, or URL WILL miss any occurrence that lives inside a template — `*.tftpl`, `*.tmpl`, `*.j2`, a Terraform `templatefile()` argument, an ERB/Jinja body — because the literal is assembled at render time from a logical name plus interpolation, not stored verbatim. Before asserting "host X is referenced nowhere", glob-enumerate the template mechanisms in the repo and search each on the logical name AND on path fragments, not only the fully-rendered literal:

```bash
# enumerate template files, then search them on the logical name / path fragment
rg --files -g '*.tftpl' -g '*.tmpl' -g '*.j2' -g '*.erb'
rg -n 'templatefile\(' .                       # Terraform render sites
rg -n '<logical-name>|<path-fragment>' $(rg --files -g '*.tftpl' -g '*.tmpl')
```

Origin: 2026-06-27 — asserted "sage 参照ゼロ" from a literal grep, then found the reference in `servers.yml` (a templated value the literal search skipped).

## GitHub search splits hyphenated compound words

`gh issue list --search` / `gh pr list --search` tokenizes on hyphens, so a query for `foo-bar-baz` matches items containing `foo`, `bar`, OR `baz` separately — it both over- and under-matches. Do NOT assert "issue/PR is unaddressed" from a `--search` miss. Enumerate the full set and filter locally instead:

```bash
gh pr list --state all --limit 30 --json number,title,headRefName,state
gh issue list --state all --limit 50 --json number,title,state
```

Origin: 2026-06 zp-SHIN #45 — a `--search` query missed the matching PR because the hyphenated term was split; full enumeration found it.

## A concept absent from the current repo may live in a sibling repo

When a user names a concept (a host, a service, a config key) that is not in the current repo, content-grep the sibling repos under `~/ManagedProjects/` before answering "we don't have that":

```bash
rg -il '<keyword>' ~/ManagedProjects/*/
```

Use absolute-path arguments and no leading `cd` — a `chpwd` tree/ls hook pollutes stdout and can manufacture a false negative (the same trap as the git-only rule in `git-commit.md`).

Origin: 2026-07-03 — a leading `cd` triggered a shell tree hook and a shallow `find` missed a cookbook that a content grep across sibling repos would have surfaced.

## Combined short options and broken search flags UNDER-report — a non-zero count is not a complete count

The always-loaded rule covers "0 件" claims. The more dangerous shape is a **non-zero but incomplete** result set, because it is reported as a number ("8 sites") and reads as authoritative. Two independent mechanisms produce it:

**1. A multi-letter flag string is not a substring of its combined form.** Searching for the literal `-o pipefail` finds `set -o pipefail` but NOT `set -euo pipefail` or `set -uo pipefail` — in the combined forms the `o` is not adjacent to the `-`. The same applies to any short-option cluster: `-e`, `-u`, `-x`, `-eo`, `-xeuo` are all valid spellings of the same intent.

```bash
# WRONG — misses every combined form, and silently returns a plausible count
git grep -n -- '-o pipefail' -- 'cookbooks/**/*.rb'

# RIGHT — search the invariant token, then classify each hit
git grep -n 'pipefail' -- 'cookbooks/**/*.rb'
```

Rule: when the thing you are counting has more than one valid textual spelling, search the **invariant token** (`pipefail`, `insteadOf`, `ignore_failure`) and classify the hits — never a specific flag-string variant.

**2. A malformed search flag returns a truncated set instead of erroring out.** `rg --glob '*.rb'` and `ugrep --include='*.rb'` both failed in a zsh session with `--glob: No such file or directory` / `--include=*.rb: No such file or directory`, yet still printed results — a subset that omitted a file the searcher had already read with its own eyes. The warning line scrolls past; the result count looks normal.

Classification is part of the count, not a follow-up. Group hits by enclosing construct before reporting, because the same token means different things in different positions — a `set -euo pipefail` inside `execute … command` is dash-fatal, while the identical line inside a `file … content` heredoc is a shipped script with its own interpreter and is not a defect at all.

```bash
# count + classify in one pass: enclosing resource per hit
git grep -n '<token>' -- '<pathspec>' | while IFS=: read -r f ln rest; do
  start=$((ln>20?ln-20:1))
  enc=$(sed -n "${start},${ln}p" "$f" | grep -nE '^ *(execute|file|template|remote_file) ' | tail -1)
  printf '%-44s %s\n' "$f:$ln" "${enc:-<heredoc/none>}"
done
```

Origin: 2026-08-02 setup — a `set -euo pipefail` sweep reported 8 unrecorded dash-fatal sites; the true count was 9 (`lxc-monitoring:430` uses `set -uo pipefail`). A follow-up `-o pipefail` search returned only 5 files and did not include a hit that had already been read directly, and both `rg --glob` and `ugrep --include` returned truncated sets after a flag-parse error. `git grep` on the bare token plus per-hit classification settled it, and separated 5 non-defects (heredoc-shipped scripts, a darwin-only block) from the 9 real ones.
