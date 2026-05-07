---
description: "Guidelines for prose output: documents, business communication, and conversational chat replies"
---

# Writing Guidelines

These principles apply to any prose output — formal documents AND day-to-day chat replies. The structural enforcement scales with length, but the philosophy and Japanese-output rules are constant.

## Core Philosophy

Word precision equals thought precision. The act of finding concrete replacements for vague words deepens understanding itself. If you cannot express it concretely, you do not understand it precisely.

## Before Writing

Identify the reader: who are they, what do they already know, and what decision will they make from this text? Marginal utility varies per reader — information obvious to the reader adds zero value.

## Structure: Pyramid Principle

Every document must follow the Pyramid Principle:

1. Lead with the conclusion (BLUF: Bottom Line Up Front)
2. Support with key arguments grouped by MECE (Mutually Exclusive, Collectively Exhaustive)
3. Each level answers "why?" or "how?" from the level above
4. Each paragraph opens with a topic sentence that states that paragraph's conclusion
5. Keep hierarchy to 3 levels or fewer

## Expression

- Replace every adjective and adverb with a concrete number or fact. If you lack the data, flag it rather than using a vague word
- Default to narrative prose; use bullet points only when they genuinely aid comprehension
- State assertions directly. When uncertain, quantify the uncertainty rather than hedging with "maybe" or "probably"

## Marginal Utility Test

Every sentence must earn its place:

- Would removing this sentence reduce the document's value? If not, remove it
- Even a few redundant characters should be cut
- A shorter document that conveys the same information is always better

## Volume Control

- Body max 6 pages; excess goes to appendix
- If 2 pages suffice, stop at 2

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
