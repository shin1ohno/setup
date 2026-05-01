---
name: writing
description: |
  Use this skill any time the user wants to write, draft, edit, proofread, restructure, or improve prose — emails, proposals, reports, RFCs, vision documents, blog posts, slack/notion posts, or any text where structure and concision matter. Also triggers when the user asks for "Pyramid Principle" structuring, BLUF rewriting, marginal-utility editing, "make this shorter", "tighten this", "fix the structure", or supplies an existing draft and asks for review. Loads writer + editor personas and optional DVQ/RFC templates; runs a 3-phase Plan → Write → Edit pipeline with up to 3 revision cycles.
---

# Writing Skill

Cowork-adapted version of the Pyramid Principle + Marginal Utility writing pipeline. The pipeline assumes the user wants production-grade business writing, not casual chat.

## Argument Parsing

Treat the user's message as the task. If it starts with the keyword `dvq` or `rfc`, load the matching template before Step 1:

- `dvq [topic]` — Anthropic-style strategic vision document
- `rfc [topic]` — technical decision document

Strip the keyword from the topic before passing it on.

## Preparation

Read these files into context before drafting:

1. `personas/document-writer.md` — writer persona
2. `personas/marginal-utility-editor.md` — editor persona
3. (if template keyword detected) `templates/dvq.md` or `templates/rfc.md`

## Workflow

Execute three steps sequentially. Delegate each to an Agent (`general-purpose` subagent) so personas are isolated and the steps don't bleed.

### Step 1: Plan (structure design)

Subagent prompt includes the writer persona. Instructions:

- Identify reader: who they are, what they already know, what decision/action this document supports
- If a template was loaded, use its structure as the starting point
- Design structure per Pyramid Principle: conclusion (1 sentence) → arguments (MECE-grouped) → evidence
- Verify each argument answers "why?" or "how?" from the conclusion
- Hierarchy ≤ 3 levels
- Decide format (short / medium / long)

### Step 2: Write (drafting)

Subagent prompt includes writer persona + Step 1 output. Instructions:

- Write per the structure
- Conclusion first
- Topic sentence at the head of each paragraph
- Narrative prose; bullets only when they aid comprehension
- Concrete numbers and facts instead of adjectives/adverbs
- Output the draft only — no meta-commentary

### Step 3: Edit (marginal utility)

Subagent prompt includes editor persona + Step 2 draft. Instructions:

- Verify Pyramid structure (conclusion-first, topic sentences, MECE, ≤ 3 levels)
- Apply marginal utility test against the identified reader
- Expression: adjective → number, passive → active, drop "you can"/"there is" padding
- Reader-level adaptation: if reader is non-technical, flag undefined technical terms on first use
- Scannability: paragraphs ≤ 5 sentences; headings carry the conclusion word; lists keep parallel grammatical structure
- Volume: body ≤ 6 pages; excess to appendix
- Output: editing report + revised draft

### Cycle Decision

If editor returns "revision needed", loop back to Step 1 with the editor's feedback. Cap at 3 cycles. If the cap is hit, output the best draft so far as final.

## Final Output

Present the editor-approved (or final-cycle) draft to the user.

## When NOT to use

- Single-sentence rewording
- Code comments (use the project's coding conventions instead)
- Casual chat replies
- Translation-only tasks (Cowork has no separate translation skill, but the 3-phase pipeline is overkill)
