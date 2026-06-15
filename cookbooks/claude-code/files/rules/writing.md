---
description: "Guidelines for prose output: documents, business communication, and conversational chat replies"
---

# Writing Guidelines

These principles apply to any prose output — formal documents AND day-to-day chat replies. The structural enforcement scales with length, but the philosophy and Japanese-output rules are constant.

## Before Writing

Identify the reader: who are they, what do they already know, and what decision will they make from this text? Marginal utility varies per reader — information obvious to the reader adds zero value.

## Conversational Output

These principles apply to chat replies, not just formal documents — but with relaxed structural enforcement:

- BLUF stays mandatory. Lead with the conclusion in every reply
- Strict 3-level Pyramid is overkill for chat. 1-2 levels is fine; the constraint is "topic sentence per paragraph", not the full hierarchy
- Reference rather than reproduce: cite "see CLAUDE.md `Japanese Output Discipline`" or "see `rules/debugging.md`" instead of pasting protocol text inline. Long extracted text in chat is reading-cost without marginal utility
- Marginal utility test still applies sentence-by-sentence
- Length scales to the question's complexity. A 3-line factual question gets a 3-line answer. A multi-faceted plan question gets the full plan structure

## Japanese-Specific

When writing in Japanese: prioritize clarity over politeness in internal documents. Japanese tends toward verbosity through honorifics and indirect phrasing — resist this in business writing.

For style rules (ですます調, banned hedge phrases, さん付け, English-rule-name treatment), the canonical reference is the **Japanese Output Discipline** section of `~/.claude/CLAUDE.md`. That section applies to all Japanese output — chat replies, plan documents, commit-message bodies in Japanese (rare; English is default for commits), retro notes. Do not duplicate its rules here; treat it as the single source of truth and follow it.
