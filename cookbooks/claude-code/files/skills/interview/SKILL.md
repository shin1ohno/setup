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
- **Save as you go.** Create `SPEC.md` with the skeleton below after the first answers, and update it after every batch of answers. Never hold more than one batch of unapplied answers: a long interview must survive compaction or a dropped session, and the file is the only durable copy.
- Write each decision with its reason inline. An open design question stays as `TODO:` until the user answers it.

### Phase 3: Complete the Spec

`SPEC.md` (project root, or the path the user names) uses these sections, omitting any with nothing true to say:

1. **Summary** — one or two paragraphs.
2. **Motivation** — the problem, who has it, and the use cases. The most important section; it can be long.
3. **Explanation** — how a consumer uses the change once built: commands, API, config, with pseudo-code. Written like a reference and getting-started guide.
4. **Requirements** — numbered, with priority (Must / Should / Could), each testable.
5. **Drawbacks** — why not do this.
6. **Considered Alternatives** — the alternatives discussed and why each lost. Record every design decision made during the interview here.
7. **Security and Privacy Considerations** — trust boundaries, credentials, data exposure.
8. **Mission Scope** — `### Out of scope` and `### Expected Outcomes` (acceptance criteria: testable conditions for done).
9. **Implementation Plan** — internal data models and code changes invisible to consumers; edge cases and how each is handled.
10. **Current Status** — always last (format below).

Before calling the interview complete: every `TODO:` is either decided (decision and rationale inlined) or rewritten as an implementation item in the plan, and `grep -n -i -E 'TBD|TODO|maybe|possibly|to be decided' SPEC.md` returns nothing that is still open.

**Current Status format.** During the interview:

```
## Current Status

Interview in progress.

Covered:
- Data model: field types decided, indexes decided

Remaining (~6 questions):
- Operations: rollback, monitoring
```

After the interview, and kept current by whoever implements it:

```
## Current Status

Implementation in progress. Implementers update this section as they work.

### Checklist
- [ ] <one item per deliverable>

### Updates
- YYYY-MM-DD: <what landed, with PR/commit>
```

### Phase 4: Review

Present the spec to the user (path + section list). Ask if anything needs to be added or changed before implementation. After implementation, `/feature-parity` in spec mode checks the code against this file.
