<!-- layer=writing: source of truth. Edit here, then run bin/build-instructions. Do not edit the generated files. -->
<!-- section id=claude-writing-deliverable-to-file file=CLAUDE.md order=0300 harness=neutral lazy=n -->
## Writing — Claude Code specifics

- **A deliverable goes to a FILE, not into the chat body**: a report, analysis, glossary, script or copy-paste prompt over ~30 lines OR reused / shared / iterated goes to a file FIRST (relevant repo, else scratchpad); chat carries BLUF + **absolute** path + section list; full body only on request. Detail: see `~/.claude/docs/claude-md-detail.md#deliverable-to-file`.
<!-- section id=claude-writing-medium-shape file=CLAUDE.md order=0310 harness=claude lazy=n -->
- **Each medium has its own shape**: a channel post = conclusion in the parent, evidence / detail / options as replies; a document follows the shared Writing rules; an ambiguous medium → AskUserQuestion. Detail: see `~/.claude/docs/claude-md-detail.md#medium-shape`.
<!-- section id=claude-writing-self-review-pass file=CLAUDE.md order=0320 harness=claude lazy=n -->
- **Self-review pass before presenting a multi-line Plan / report** (whether or not written to `.md`), in full: (1) delete every 禁止表現 (hedge / suggest-直訳 / 確認伺い / 後送り) → action or numeric/conditional statement; (2) compress, adjectives → numbers/facts (圧縮 / 具体性); (3) BLUF + one topic sentence per paragraph; (4) delete leaked change-narration (`No change-narration in the deliverable`). File-bound artifacts go through `/writing`; inline chat reports self-apply and `Read` `~/.agents/skills/writing/references/phrases.md` + `structures.md`. Single-line factual answers exempt. Detail: see `~/.claude/docs/claude-md-detail.md#self-review-pass`.

<!-- section id=agents-writing file=AGENTS.md order=0350 harness=neutral lazy=n -->
## Writing

Applies to any prose output — formal docs AND chat replies.

- **Reader / BLUF / length は harness 既定** — 結論先行・読者に合わせた長さ
- **Chat ≠ full Pyramid**: 1-2 levels is fine (constraint is "topic sentence per paragraph").
- **Reference, don't reproduce**: cite "see `Japanese Output Discipline`" or "see `~/.claude/rules/debugging.md`" instead of pasting protocol text inline.
- **No change-narration in the deliverable**: a report / document / proposal / spec contains only reader-facing content — never how it was authored, ordered or revised. Editing rationale and reordering / version-diff notes belong in the chat reply, crit / PR comment, or commit message. Detail: see `~/.claude/docs/agents-md-detail.md#no-change-narration`.
- **Domain-heavy documents**: bulk terminology edits follow `~/.claude/docs/domain-writing.md`.
- **Japanese prose**: clarity over politeness; canon is `Japanese Output Discipline` above (do not restate).

