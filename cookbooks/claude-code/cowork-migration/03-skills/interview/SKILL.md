---
name: interview
description: |
  Use this skill when the user wants to clarify requirements for a feature, project, decision, or workflow before doing the actual work — typical triggers are "let's spec out X", "interview me about Y", "I want to build Z, ask me what's needed", "before we implement this let's think it through", or any vague request like "make a tool for [thing]" where the scope and constraints are unclear. Runs an 8-dimension AskUserQuestion-driven interview and produces a written SPEC.md the user can review before any implementation begins. Use BEFORE building, not after.
---

# Interview Skill

Deeply explore requirements before implementation. The output is a written spec, not code.

## Argument Parsing

The user's message is the brief description of what they want to build. If it's missing or ambiguous, use AskUserQuestion to ask what they want to build.

## Workflow

### Phase 1: Initial Understanding

Read any files referenced in the user's message to understand the current state. If files are attached or paths are mentioned, examine them before asking questions.

### Phase 2: Interview

Use AskUserQuestion to explore these eight dimensions, **one or two at a time** (never as a wall of questions):

1. **User intent** — what problem does this solve, who benefits
2. **Scope** — what is explicitly in / out of scope
3. **Technical implementation** — what existing code, APIs, or infrastructure does this touch
4. **UI / UX** — what does the user see, what interactions are needed
5. **Edge cases** — what happens when input is invalid, network fails, data is missing
6. **Tradeoffs** — what are we trading off (speed vs correctness, simplicity vs flexibility)
7. **Acceptance criteria** — how do we know it works, what tests should pass
8. **Operations** — how is this deployed, monitored, rolled back

Skip dimensions that are obviously irrelevant. Dig into the hard parts the user might not have considered. Stop when all relevant dimensions are covered or the user says "that's enough".

### Phase 3: Write Spec

Create `SPEC.md` (in the workspace folder) containing:

1. **Summary** — one paragraph
2. **Requirements** — numbered list with priority (Must / Should / Could)
3. **Non-requirements** — explicitly out of scope
4. **Technical approach** — high-level implementation plan
5. **Edge cases** — known cases and how to handle them
6. **Acceptance criteria** — testable conditions for "done"

### Phase 4: Review

Present the spec to the user via a `computer://` link. Ask if anything needs to be added or changed before implementation.

## When NOT to use

- Trivial tasks where the spec would be longer than the implementation
- Tasks the user has already specified in detail
- Simple bug fixes (the bug report itself is the spec)
