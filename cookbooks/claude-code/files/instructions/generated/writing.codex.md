## Writing — Claude Code specifics

- **A deliverable goes to a FILE, not into the chat body**: a report, analysis, glossary, script or copy-paste prompt over ~30 lines OR reused / shared / iterated goes to a file FIRST (relevant repo, else scratchpad); chat carries BLUF + **absolute** path + section list; full body only on request. Detail: see `~/.claude/docs/claude-md-detail.md#deliverable-to-file`.
## Writing

Applies to any prose output — formal docs AND chat replies.

- **Reader / BLUF / length は harness 既定** — 結論先行・読者に合わせた長さ
- **Chat ≠ full Pyramid**: 1-2 levels is fine (constraint is "topic sentence per paragraph").
- **Reference, don't reproduce**: cite "see `Japanese Output Discipline`" or "see `~/.claude/rules/debugging.md`" instead of pasting protocol text inline.
- **No change-narration in the deliverable**: a report / document / proposal / spec contains only reader-facing content — never how it was authored, ordered or revised. Editing rationale and reordering / version-diff notes belong in the chat reply, crit / PR comment, or commit message. Detail: see `~/.claude/docs/agents-md-detail.md#no-change-narration`.
- **Domain-heavy documents**: bulk terminology edits follow `~/.claude/docs/domain-writing.md`.
- **Japanese prose**: clarity over politeness; canon is `Japanese Output Discipline` above (do not restate).

