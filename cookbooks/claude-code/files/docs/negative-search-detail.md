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
