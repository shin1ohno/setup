# fractal Node Trees + plasma-wiki

Load when operating a `fractal` tree (hierarchical autonomous agent loops in git
worktrees) or growing a `plasma-wiki` knowledge base — before `fractal init`,
before authoring a node's `NODE.md`, or when a node's commits, costs, or lint
gate misbehave. Every item below was paid for once by rediscovery; the SKILL.md
files do not cover them.

## Read the installed source, not just SKILL.md

Three of the defaults below silently produce a broken tree, and none are
documented. Before configuring a tree, read the installed package:
`impl/<agent>.py` (invocation, env, cost parsing), `core/commit.py` (staging
pathspecs, scope resolution), `core/node.py` (paths, init guards),
`core/pricing.py` (rate lookup). `pipx`/`uv tool` installs land under
`~/.local/share/**/site-packages/fractal/` or the plugin cache.

## The agent's config home does NOT inherit your shell's

`fractal` launches each node's agent with the agent config home pointed **inside
the node directory** (codex: `CODEX_HOME=<node_dir>/.codex`, seeded with only a
sandbox/analytics stub and an `auth.json` symlink). A provider route configured
in your interactive `~/.codex/config.toml` — a company gateway, a custom
`base_url`, an `Authorization` header — is therefore **not** inherited, and every
step fails against the vendor default endpoint.

The node directory is git-tracked, so an API key must never be written into it.
The working shape:

1. Build a machine-local config home outside the repo (`~/.codex-fractal/`,
   `chmod 700`, config `chmod 600`) that mirrors your provider route, drops MCP
   servers a node does not need (each one costs startup on **every** step), and
   keeps the sandbox value fractal itself seeds
2. Symlink each node's config at it: `ln -s ~/.codex-fractal/config.toml
   <node_dir>/.codex/config.toml`
3. Ship the generator as a script in the project so it is reproducible for later
   nodes, reading the key at run time rather than storing it

Nodes need filesystem access **outside** their worktree (the central database in
the main tree, `~/.fractal`, the gpg-agent socket) for `radio`, `node finish`,
`cost`, and signed commits — so the sandbox value fractal seeds is the one to
mirror. Writing a config with an approval-free, sandbox-disabled profile is a
mutation the auto-mode classifier blocks: surface the exact command, get explicit
authorization naming the setting, then run it (see `~/ManagedProjects/setup/.claude/rules/infrastructure.md`
"Auto-Mode Classifier Boundary").

## Cost caps only work when the model is explicit

For a token-priced agent, fractal prices usage against the LiteLLM public rate
table and refreshes it at run start **only when a model is set on the node**. With
no `--model`, the pricing refresh never runs, spend records as unpriced, and
`--max-cost` / `--max-iter-cost` cannot trip ("budget guards cannot trip").

Pass `--model` explicitly, and confirm the id resolves: the lookup chain tries the
exact id, then `openrouter/<id>`, then the id with its author prefix stripped. A
gateway-prefixed id (`openai/<model>`) resolves via that last hop when the bare
name is in the table — verify with the table itself before trusting a cap:

```bash
curl -s https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print([k for k in d if k.endswith("<bare-model-name>")][:5])'
```

## `--scope` double-nests under `--path`

With a sub-project node (`--path=projects/<name>`), the commit boundary already
defaults to that project directory. Passing `--scope=projects/<name>` as well
nests it again (`projects/<name>/projects/<name>`) and nothing is ever in scope.
Omit `--scope` for a sub-project node; use it only to narrow *within* the project.

## Verify every `node update` against `config.json`

`fractal node update <node> --max-cost=N` prints an old → new confirmation and
updates the registry, but the change does not always reach the node's
`config.json`. Re-read the file after every update; a stale value silently ends
the run early:

```bash
python3 -c "import json;print(json.load(open('<node_dir>/config.json'))['max_cost'])"
```

## Budget shape: parents need ~1.6× what the arithmetic suggests

Measured on a research tree (frontier model, 5 steps + 5 syncs per iteration,
leaf children on a cheaper model with a trimmed step list):

| Unit | Cost |
|---|---|
| Leaf child, one mission, 4–5 output pages | $1.85–2.0 (≈$0.46/page) |
| Parent iteration (5 steps + 5 syncs, effort high) | $4–5 |
| Parent total: children + planning/delegation + 2–3 integration iterations | $25–30 |

A cap sized for "children + planning" strands the parent mid-integration with its
children's work unmerged. Budget the integration explicitly, and re-price after
observing **one** node rather than guessing for the whole wave. Sync is a billed
step that runs once per numbered step, so an iteration with N step files costs
about 2N agent invocations.

## Node seeds do not reach the parent

`.git/info/exclude` excludes only the **user** node's data dir. Agent-node seeds
(`NODE.md`, `plans/`, `memory/`) are stripped on merge-up by design, so a
deliverable parked in a node dir never ships — and, usefully, the final PR
contains only project files. Say so in `NODE.md`; agents otherwise assume their
memory is part of the record.

## `fractal init` rejects branch names containing `/`

The user node is initialized on the current branch, and a `/` in it is refused.
So the base branch must be slash-free (`wd-base`), which collides with
`feat/…`-style repo conventions. Open the PR with a mapped refspec instead of
renaming:

```bash
git push origin wd-base:docs/<topic>
gh pr create --head docs/<topic> --base main
```

## plasma-wiki: two constraints that bite immediately

- **`naming.validate: ["ascii","identifier"]`** (written into `.wiki/settings.json`
  at init) forbids hyphens in page names, so `working-cadence` fails and
  `working_cadence` is required — the opposite of a kebab-case repo convention.
  Check the generated settings before authoring pages
- **The desc/label period rule accepts only an ASCII `.`** (`wiki/core/wiki.py`),
  so every Japanese `desc` ending in `。` is reported as a hard issue. The seeded
  `scripts/lint.sh` only *warns* on wiki lint, so it is not a gate at all. Append
  a gate that fails on structural issues while filtering that one rule:

  ```bash
  STRUCTURAL="$(wiki lint --path="$WIKI_DIR" 2>/dev/null \
      | grep -v 'Missing period in' \
      | grep -vE '^[0-9]+ issues?, [0-9]+ notes?\.$' \
      | grep -vE '^[[:space:]]*$' || true)"
  [[ -n "$STRUCTURAL" ]] && { echo "$STRUCTURAL" >&2; exit 1; }
  ```

- **Concurrent nodes collide on new-directory indexes.** Two branches creating the
  same directory produce an add/add conflict in its `_index.md` body. Create every
  directory and index in a serial Wave 0 and require nodes to leave index bodies
  (below `***`) empty

## Tree shape that produced usable output

Contracts-first, then fan out, then verify separately:

1. **Wave 0 (serial, operator)** — freeze the contracts as wiki pages: grading
   definitions, the verification protocol, source rules with concrete fetch
   commands, page templates, and the per-axis question list. Commit before any
   node exists; children fork a branch, not a working tree
2. **Wave 1 (parallel collectors)** — one node per axis, each owning a disjoint
   file prefix stated in its `NODE.md` (directory-granular scopes cannot express
   file-level ownership). Collectors record findings but **do not** judge them
3. **Wave 2 (independent verifier)** — a separate node tries to refute each claim
   through fixed lenses and writes the verdict. Collector-as-judge is the failure
   mode this prevents
4. **Wave 3 (synthesis)** — decisions and the reader-facing document, forbidden
   from editing the evidence it reads

Two `NODE.md` clauses did most of the quality work:

- **"Verify the citation/source metadata against the record"** as a completion
  requirement. A verifier given this corrected 24 of 43 source pages, including a
  fabricated author attribution and a wrong DOI — defects no amount of prose
  review catches
- **"Record what you could not reach, with the endpoints and queries you tried"**.
  Without it, agents silently narrow scope; with it, the gaps are auditable and
  the next run does not repeat dead searches

## Operating the tree

Poll `fractal node list` / `node status <b>` / `node cost spent <b>` /
`node activity <b>`. `cost spent` covers the whole subtree; `activity`'s cost
column is the node's own steps, and both are per-run. A step in progress records
no cost, so **flat spend plus a live `active` step is normal, not a stall** —
classify against `activity` and the node's `codex.err`/agent log before killing
anything. Steer by editing `NODE.md` (re-read every step) or `fractal radio send
<msg> --node=<branch> --subject=… --priority=<0-10>` (priority is an int; a bare
send with no target is refused).

Merge finished subtrees with `fractal node merge <branch>` from the repo root, run
`wiki update` after each merge, and tear the tree down with `fractal reset` once
the PR is merged (worktrees and branches go, wiki and history stay).
