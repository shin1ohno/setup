---
name: bootstrap-docs-hub
description: >
  Scaffold a new documentation-hub repository for a project: README.md, CLAUDE.md (AI agent instructions), .claude/rules/ discipline files, bundled skills/agents (interview, retro, writing, notion-cli, claude-docs-researcher, session-retrospective, sync-bundled-tools), .gitignore, and an initial git commit.
  Use when user asks to "set up a docs hub", "create a documentation repository", "新しいプロジェクトのドキュメントハブを作る",
  "ドキュメント管理リポジトリを scaffold", "init docs project", or starts a fresh repo intended to manage external doc links (Notion, Slack, etc.) rather than source code.
---

# Bootstrap Documentation Hub

Generates a documentation-hub repository skeleton matching the conventions documented in this skill's templates. Intended for projects whose primary purpose is to be a single entry point that links to external documentation (Notion, Slack, etc.) rather than holding source code.

## What gets created

```
<target>/
├── README.md                                  # human-facing project hub
├── CLAUDE.md                                  # AI agent instructions
├── .gitignore                                 # excludes settings.local.json etc.
└── .claude/
    ├── rules/
    │   ├── communication-style.md             # Japanese style, Pyramid Principle
    │   ├── work-discipline.md                 # AskUserQuestion, Act/Plan/Verify
    │   ├── external-tools.md                  # probe-before-assert
    │   ├── content-freshness.md               # date annotations on links
    │   └── parallel-execution.md              # sub-agent parallelism
    ├── skills/
    │   └── sync-bundled-tools/                # diff bundled tools against upstream
    │       └── SKILL.md
    └── agents/                                # populated in Step 5 if user opts in
```

`.claude/skills/` and `.claude/agents/` are then optionally populated with bundled tools from `shin1ohno/setup` (interview, retro, writing, claude-docs-researcher, session-retrospective) and from `kouzoh/coding-agent-plugins` (notion-cli).

## Workflow

### Step 1: Gather project inputs

Use AskUserQuestion to collect:

- **Project name**: the canonical name used in README / CLAUDE.md headings (any string)
- **Owner name and GitHub handle**: full name + handle of the repository owner shown in README
- **One-sentence purpose**: a single sentence describing the project (e.g. "A docs hub consolidating internal decisions and roadmap for product X")
- **Target directory**: default = current working directory

If the user provides a partial answer, fill in the remaining fields with `TBD` and proceed.

### Step 2: Verify target directory

```bash
TARGET="<target>"
test -d "$TARGET" || mkdir -p "$TARGET"
cd "$TARGET"

# If not a git repo, ask before `git init` — this is a destructive-ish state change.
test -d .git || echo "(not a git repo — will git init after confirmation)"
```

Confirm with the user before running `git init` if the directory is not yet a repo.

### Step 3: Scaffold files from templates

Template root: `~/.claude/skills/bootstrap-docs-hub/templates/`

For each template:

```bash
TEMPLATE_ROOT="$HOME/.claude/skills/bootstrap-docs-hub/templates"
TODAY=$(date +%Y-%m-%d)

# README.md and CLAUDE.md need placeholder substitution
for tmpl in README.md CLAUDE.md; do
  sed \
    -e "s/{{PROJECT_NAME}}/$PROJECT_NAME/g" \
    -e "s/{{PROJECT_PURPOSE}}/$PROJECT_PURPOSE/g" \
    -e "s/{{OWNER_NAME}}/$OWNER_NAME/g" \
    -e "s/{{OWNER_HANDLE}}/$OWNER_HANDLE/g" \
    -e "s/{{TODAY}}/$TODAY/g" \
    "$TEMPLATE_ROOT/$tmpl.tmpl" > "$tmpl"
done

# .gitignore
cp "$TEMPLATE_ROOT/gitignore.tmpl" .gitignore

# Rules
mkdir -p .claude/rules
cp "$TEMPLATE_ROOT/rules/"*.md .claude/rules/

# sync-bundled-tools skill
mkdir -p .claude/skills/sync-bundled-tools
cp "$TEMPLATE_ROOT/skills/sync-bundled-tools/SKILL.md" .claude/skills/sync-bundled-tools/
```

If `$PROJECT_PURPOSE` contains characters that would break `sed` (slashes, ampersands), use a different delimiter or escape, e.g. `sed -e "s|{{PROJECT_PURPOSE}}|$PROJECT_PURPOSE|g"`.

### Step 4: Ask which bundled tools to add

Default set:

- **Skills**: `interview`, `retro`, `writing`, `notion-cli`
- **Agents**: `claude-docs-researcher`, `session-retrospective`

Use AskUserQuestion (multiSelect) to let the user opt in / out per item. Source URLs:

| Item | Upstream |
|---|---|
| `interview` | `shin1ohno/setup` `cookbooks/claude-code/files/skills/interview/SKILL.md` |
| `retro` | `shin1ohno/setup` `cookbooks/claude-code/files/skills/retro/SKILL.md` |
| `writing` | `shin1ohno/setup` `cookbooks/claude-code/files/skills/writing/` (subdir, includes personas/ + templates/) |
| `notion-cli` | `kouzoh/coding-agent-plugins` `plugins/notion-cli/skills/notion-cli/SKILL.md` |
| `claude-docs-researcher` | `shin1ohno/setup` `cookbooks/claude-code/files/agents/claude-docs-researcher.md` |
| `session-retrospective` | `shin1ohno/setup` `cookbooks/claude-code/files/agents/session-retrospective.md` |

### Step 5: Fetch and install selected tools

For each approved item, prefer fetching from upstream so the bundled copy is fresh:

```bash
# Single file (agent)
gh api "repos/<repo>/contents/<path>" --jq '.content' | base64 -d > "<dest>"

# Directory (skill with multiple files)
# List, then loop
gh api "repos/<repo>/contents/<dir>" --jq '.[].path' | while read -r p; do
  mkdir -p ".claude/skills/<name>/$(dirname "${p#<dir>/}")"
  gh api "repos/<repo>/contents/$p" --jq '.content' | base64 -d > ".claude/skills/<name>/${p#<dir>/}"
done
```

If `gh` is unavailable, fall back to copying from `~/.claude/skills/<name>/` if present (likely the case for the user's own machine). Note in the commit message which fallback was used.

### Step 6: Initial commit

```bash
git init 2>/dev/null  # no-op if already a repo
git add -A
git commit -m "Initialise project documentation hub

Scaffolded by bootstrap-docs-hub skill. Contains README, CLAUDE.md,
discipline rules, sync-bundled-tools skill, and bundled tools selected
by the user.
"
```

Do NOT push automatically.

### Step 7: Report and next actions

Output:

- File tree summary (`ls -R` or similar)
- Bundle registry: which tools were fetched from which upstream
- Suggested next actions:
  - Fill in TBD sections in README.md (Notion / Slack links, latest status, team)
  - `gh repo create <slug> --private --source=. --remote=origin --push` if not yet on GitHub
  - Schedule a periodic invocation of `/sync-bundled-tools` to track upstream drift

## Templates registry

The templates this skill uses are at `~/.claude/skills/bootstrap-docs-hub/templates/`:

| Template path | Purpose |
|---|---|
| `README.md.tmpl` | Human-facing project hub skeleton with placeholder substitution |
| `CLAUDE.md.tmpl` | AI agent instructions skeleton |
| `gitignore.tmpl` | Standard exclusions |
| `rules/*.md` | Five discipline rule files (copied verbatim, no substitution) |
| `skills/sync-bundled-tools/SKILL.md` | The sync skill for ongoing drift management |

Placeholders supported in `.tmpl` files: `{{PROJECT_NAME}}`, `{{PROJECT_PURPOSE}}`, `{{OWNER_NAME}}`, `{{OWNER_HANDLE}}`, `{{TODAY}}`.

## When to invoke

- Starting a fresh project that will live primarily as a doc/link hub (not a code repo)
- User asks to "set up the standard docs structure" in a new repository
- After `git init` of an empty repo intended as a documentation collection

Do NOT invoke for:

- Existing code repositories (the scaffold assumes empty starting state)
- Projects whose primary deliverable is source code
- Single-page documentation files (just write the file directly)
