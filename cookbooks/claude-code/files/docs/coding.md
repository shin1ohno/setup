# Coding Conventions — Source Comments, Error Boundaries, Retry Backoff

Load when writing or reviewing code in any language. Language-agnostic; a project's own CLAUDE.md, rules or style guide wins on conflict. Adapted from sorah/config `sorah-guides/skills/coding`.

## source-comments
## Source comments

A comment records what the code cannot say: why a non-obvious approach was chosen, an external constraint the code must satisfy (protocol, spec, upstream bug, API quirk), or an assumption or limitation a reader would otherwise rediscover. It is the source-code case of `No change-narration in the deliverable`.

- **Write for a stranger reading the file, not a reviewer reading the diff.** The reader has never seen the PR, the ticket, the review discussion or the previous version of the code.
- **Default to one line.** Use two or three only when one cannot carry the constraint. A doc comment states what the thing is and what it guarantees in a sentence or two; it is not a design document.
- **State a fact, not a narrative.** An em dash, a semicolon, or a colon that introduces an explanation is the signal to stop and cut. So is a second sentence opening with "But", "So", "Note that" or "In practice".
- **Cite a discussion instead of retelling it.** A bare PR, issue or upstream-bug reference is the compact form of a long rationale: `# Bound set from the measurements in #1234.` Straightforward code gets no comment and no link.
- **Deferred cleanup is a `TODO:`** naming the trigger and the replacement, so it is a grep away: `# TODO: remove once the v2 endpoint graduates; superseded by Order#total.`
- **Origins go to the commit, the PR or a docs file.** An incident story (`Origin: <date> …`) belongs in the commit message, the PR body or a `docs/*-detail.md` origin section. The comment keeps at most the reference (`# See #812.`).

Never write:

- **Change narration**: anything phrased against a previous state — "now falls back to", "no longer needed", "previously failed the canary". The comment outlives the change; the diff and the commit message own that story.
- **Retold discussion**: "as discussed", "the spec called this out", "which is accepted".
- **Alternatives-considered essays**: defending the design against one that is not in the file.
- **Tutorial voice**: "the obvious implementation is X and it is wrong", "a consumer that wants Y calls Z".
- **Language tutorials**: what `frozen_string_literal` does, SQL `ON DELETE` semantics. The reader knows the tool.
- **Speculative threat or failure narratives**: name the risk in a clause instead of writing out the incident.
- **Inventories of sibling code**: lists of other classes that do the same thing. They go stale silently and grep answers them.
- **Markdown emphasis** inside comments.

Tests follow the same rules; let the example name carry the intent instead of narrating the setup.

Scope: apply to lines you add or change. Do not rewrite untouched comments in the same change — a mass rewrite is diff noise and costs `git blame`.

Before and after, same fact:

```ruby
# Retries with a fresh connection rather than reusing the pooled one — the
# pooled connection is what went stale in the first place, so reusing it is
# the obvious implementation and it is wrong: the second attempt then fails
# exactly as the first did, which is what happened before this changed.
```

```ruby
# A pooled connection may be stale, so the retry opens its own.
```

## error-boundaries
## Error boundaries

- Let errors propagate. Catch a specific error only to add context, clean up, convert it at a boundary, or recover from an expected condition.
- Do not rescue only to log and re-raise; the runtime or framework already reports what propagates.
- When a boundary converts failures into one error type:
  - Wrap every failure unconditionally. Code behind the boundary raises ordinary errors, never the wrapper type, so the boundary has no "already wrapped?" branch.
  - Keep the cause out of the wrapper's message. The message says what failed at the boundary; the cause (`raise Wrapped, "fetch failed", cause: e` in Ruby, `#[source]` / `.context()` in Rust, `raise … from e` in Python) carries the original type and message.
  - Log the cause. The wrapper's message alone says nothing about what went wrong.
- Exception: a process that must never fail its host — a Claude Code hook, a cron/loop iteration, a mitamae guard — may rescue broadly and exit 0. Say so in one line at the rescue site, and log the error class.

## retry-backoff
## Retry backoff

Space retries with exponential backoff that is capped, jittered, and computed in floats:

```
delay = min(base * 2^(attempt - 1), cap) * (0.5 + 0.5 * uniform[0, 1))
```

```ruby
delay = [BASE * (2**(attempt - 1)), MAX].min * (0.5 + (0.5 * rand))
```

```rust
let exp = base.as_secs_f64() * 2f64.powi(attempt.saturating_sub(1).min(30) as i32);
let delay = Duration::from_secs_f64(exp.min(cap.as_secs_f64()) * (0.5 + 0.5 * fastrand::f64()));
```

- A fixed delay, or an exponential one without jitter, makes clients that failed together retry together (every edge host reconnecting at the same instant after a server restart).
- Cap the exponent too where the arithmetic can overflow before the `min` applies (Python `2 ** 1024` cannot become a float; Rust `powi` of a large `i32` becomes `inf`).
- Reset the attempt counter after a success that lasted longer than the cap.
