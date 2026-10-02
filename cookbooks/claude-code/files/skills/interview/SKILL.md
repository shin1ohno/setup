---
name: interview
description: Interview the user to clarify requirements before building a large feature. Produces a SPEC.md.
user-invocable: true
argument-hint: "[feature description]"
---

# Interview Skill

## Purpose

Deeply explore requirements for a feature before implementation begins. The output is a written spec, not code.

## Argument Parsing

The invocation arguments (the user's request text) are a brief description of the feature. If omitted, ask the user what they want to build (use a question tool if available, otherwise write numbered options in the body; Claude Code: AskUserQuestion / Codex: request_user_input).

## Workflow

### Phase 1: Initial Understanding

Read any files referenced in the invocation arguments to understand the current state.

### Phase 2: Interview

Ask the user questions repeatedly (question tool, if available; otherwise numbered options in the body) to explore these dimensions:

1. **User intent** — What problem does this solve? Who benefits?
2. **Scope** — What is explicitly in scope? What is out of scope?
3. **Technical implementation** — What existing code, APIs, or infrastructure does this touch?
4. **UI/UX** — What does the user see? What interactions are needed?
5. **Edge cases** — What happens when input is invalid, the network fails, or data is missing?
6. **Tradeoffs** — What are we trading off (speed vs correctness, simplicity vs flexibility)?
7. **Acceptance criteria** — How do we know it works? What tests should pass?
8. **Operations** — How is this deployed? How do we monitor it? What does rollback look like?

Guidelines:
- Ask 1-2 questions at a time, not a wall of questions
- Skip dimensions that are obviously irrelevant (e.g., no UI/UX for a CLI tool)
- Dig into the hard parts the user might not have considered
- Stop when all dimensions are covered or the user says "that's enough"

### Phase 3: Write Spec

Write `SPEC.md` in the project root containing:

1. **Summary** — One paragraph describing the feature
2. **Requirements** — Numbered list with priority (Must / Should / Could)
3. **Non-requirements** — Explicitly out of scope
4. **Technical approach** — High-level implementation plan
5. **Edge cases** — Known edge cases and how to handle them
6. **Acceptance criteria** — Testable conditions for "done"

### Phase 4: Review

Present the spec to the user. Ask if anything needs to be added or changed before implementation.
