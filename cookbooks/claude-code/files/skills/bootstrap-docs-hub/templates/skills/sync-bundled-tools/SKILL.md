---
name: sync-bundled-tools
description: >
  Compare bundled .claude/skills/* and .claude/agents/* against their upstream source repositories and report drift.
  Primary upstream is github.com/shin1ohno/setup/cookbooks/claude-code/files (for skills/agents originating from that cookbook).
  External upstreams (e.g. kouzoh/coding-agent-plugins for notion-cli) are handled per the registry below.
  Use when user asks to "sync skills", "check skill updates", "upstream diff", "cookbook drift", "同梱 skill の差分確認", "上流と同期".
---

# Sync Bundled Tools from Upstream

This repo bundles skills and agents from external sources for team portability. Over time, the upstreams may receive bug fixes and improvements. This skill diffs the bundled copies against their upstream and applies selected updates.

## Upstream Registry

| Bundled path | Upstream repo | Upstream path |
|---|---|---|
| `.claude/skills/interview/` | `shin1ohno/setup` | `cookbooks/claude-code/files/skills/interview/` |
| `.claude/skills/retro/` | `shin1ohno/setup` | `cookbooks/claude-code/files/skills/retro/` |
| `.claude/skills/writing/` | `shin1ohno/setup` | `cookbooks/claude-code/files/skills/writing/` |
| `.claude/skills/notion-cli/` | `kouzoh/coding-agent-plugins` | `plugins/notion-cli/skills/notion-cli/` |
| `.claude/agents/claude-docs-researcher.md` | `shin1ohno/setup` | `cookbooks/claude-code/files/agents/claude-docs-researcher.md` |
| `.claude/agents/session-retrospective.md` | `shin1ohno/setup` | `cookbooks/claude-code/files/agents/session-retrospective.md` |

`.claude/rules/*.md` はこのプロジェクト固有のため同期対象外。

## Workflow

### Step 1: Enumerate bundled items

```bash
ls -d .claude/skills/*/ .claude/agents/*.md 2>/dev/null
```

### Step 2: Diff each tracked item against upstream

For each registry entry with a known upstream, fetch the upstream content and diff:

```bash
# Single file (agent)
gh api "repos/<upstream-repo>/contents/<upstream-path>" --jq '.content' | base64 -d > /tmp/upstream.md
diff -u <bundled-path> /tmp/upstream.md

# Directory (skill with multiple files)
mkdir -p /tmp/upstream-skill && cd /tmp/upstream-skill
gh api "repos/<upstream-repo>/contents/<upstream-path>" --jq '.[].path' \
  | xargs -I{} sh -c 'gh api "repos/<upstream-repo>/contents/{}" --jq ".content" | base64 -d > "$(basename {})"'
diff -ru <bundled-path> /tmp/upstream-skill
```

If `gh api` returns 404, the upstream path moved or was deleted. Flag as "upstream missing".

### Step 3: Classify

For each bundled item:

- **Identical**: upstream content matches → no action
- **Drift**: upstream changed → candidate for sync
- **Upstream missing**: 404 from `gh api` → manual investigation
- **Untracked (no upstream)**: in registry as `—` → skip

### Step 4: Report and confirm

Present a single table:

```
| Path | Status | Upstream commit-ish |
|---|---|---|
| .claude/skills/interview/SKILL.md | drift (5 lines changed) | shin1ohno/setup@<sha> |
| .claude/agents/session-retrospective.md | identical | — |
| .claude/skills/notion-cli/SKILL.md | drift (rewrite) | kouzoh/coding-agent-plugins@<sha> |
```

Use AskUserQuestion (multiSelect) to let the user pick which drifted items to sync.

### Step 5: Apply selected syncs

For each approved item:

1. Fetch upstream content (re-fetch to get the latest at sync time)
2. Write to the bundled path (overwrites existing)
3. Show short diff summary in the response
4. `git add` the changes

### Step 6: Commit

Single commit covering all approved syncs. Include the upstream commit SHAs in the body for audit:

```
chore: Sync bundled skills/agents from upstream

- .claude/skills/interview/SKILL.md ← shin1ohno/setup@<sha>
- .claude/agents/session-retrospective.md ← shin1ohno/setup@<sha>
- .claude/skills/notion-cli/SKILL.md ← kouzoh/coding-agent-plugins@<sha>
```

Do NOT push automatically. Leave push to the user.

## Helper: Get the upstream commit SHA at sync time

```bash
gh api "repos/<upstream-repo>/commits?path=<upstream-path>&per_page=1" --jq '.[0].sha'
```

This captures the commit SHA of the file at the moment of sync, useful for the commit message.

## Newly available upstream items (optional)

After the diff pass, optionally scan upstream for items NOT yet bundled:

```bash
gh api repos/shin1ohno/setup/contents/cookbooks/claude-code/files/skills --jq '.[].name'
gh api repos/shin1ohno/setup/contents/cookbooks/claude-code/files/agents --jq '.[].name'
```

Surface anything new with a one-line description (from frontmatter), let user decide whether to adopt. Do not auto-bundle.

## Exclusions

- `.claude/rules/*.md` — project-specific, never sync from cookbook
- `CLAUDE.md` — project-specific, never sync as-is
- Anything with `upstream: —` in the registry above

## When to invoke

- Periodically (e.g., monthly) as a maintenance pass
- When the user mentions "上流が更新された" / "cookbook が変わった"
- Before a major project milestone, to ensure team has latest bundled tools
- After bundling a new skill/agent (to register its upstream)

## Maintenance of this skill

When bundling a new skill or agent into this repo, update the **Upstream Registry** table above with its source. Without that entry, the sync skill will skip it as "untracked".
