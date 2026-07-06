# Claude Code Plugin Integration — Examples & Origin Notes

## self-describing-skill-pointers

The always-loaded summary keeps a compact one-line index of these plugins. The full per-plugin prose (verbatim from the original rule) is below.

These plugins self-advertise their own triggers via frontmatter — Claude auto-invokes on match. Use:

- `mcp-server-dev` skills — building/designing an MCP server (deployment models, tool design, auth, interactive apps); invoke before writing server code
- `frontend-design` skill — non-trivial UI implementation (new component, page redesign, visual system); invoke before writing CSS/component code
- `playground` skill — quick interactive HTML exploration (single-file live-controls playground)
- `claude-automation-recommender` skill (`claude-code-setup` plugin) — onboarding an unfamiliar repo for Claude Code setup guidance; read-only, recommends 1-2 of each automation type
- `document-skills` (`anthropic-agent-skills`) — create/edit Office formats (DOCX/PDF/PPTX/XLSX)
- `/design-md:generate` (`design-md`, `saladdays-skills`) — generate a `DESIGN.md` design-system rulebook for a product with 3+ AI-generated screens needing visual cohesion
- `/roundtable:start` (`roundtable`, `saladdays-skills`) — structured multi-expert deliberation on cross-domain judgment calls ("レビューして" / "多角的に評価" / "専門家に聞きたい" / "議論して")
- `hookify` plugin — create a soft-reminder hook from a conversation pattern ("whenever X happens, warn me"). Rules live in `.claude/hookify.{rule-name}.local.md`. Do NOT use hookify for hard guards (commit gating, tool-input mutation, whitespace/newline enforcement) — those are mandatory Ruby hooks in `cookbooks/claude-code/files/hooks/`
- `plugin-dev` plugin skills (`agent-development`, `command-development`, `hook-development`, `mcp-integration`, `plugin-settings`, `plugin-structure`, `skill-development`) — building a new Claude Code plugin; avoids placing `skills/`/`commands/` inside `.claude-plugin/`
