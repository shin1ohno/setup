---
name: research
description: Research a topic using the memory MCP and web search. Persists findings automatically.
user-invocable: true
argument-hint: "[topic or question]"
---

# Research Skill

## Purpose

Investigate a topic by searching the existing knowledge store (the memory MCP) and the web, then persist findings automatically.

## Argument Parsing

`$ARGUMENTS` is the research topic or question. If omitted, use AskUserQuestion to ask what to research.

## Workflow

### Step 1: Search Existing Knowledge

Launch 2 `researcher` agents **in parallel** via the Agent tool (both with `run_in_background: true`):

**Agent A — knowledge search:**
- Search the memory MCP via `recall` over stored knowledge (documents/chunks): relationships, facts, and overviews
- Use `top_k=15` for broad exploration
- Topic: `$ARGUMENTS`

**Agent B — memory search:**
- Search the memory MCP via `recall` for any user-related context on the topic
- Topic: `$ARGUMENTS`

### Step 2: Gap Analysis and Contradiction Detection

When both agents return, synthesize their results:

1. List what is already known (from the memory MCP)
2. **Contradiction check**: if the two searches return conflicting information, flag the contradiction explicitly and investigate which is current
3. Identify gaps: what questions remain unanswered?
4. If no gaps exist, skip to Step 4

### Step 3: Web Research

Launch a `researcher` agent to fill identified gaps:

- Provide the specific gaps as search targets
- Agent uses WebSearch to find sources, WebFetch to extract details
- **Source credibility**: tag each finding with source type (official docs / engineering blog / forum post / vendor marketing). Flag findings that rely on a single low-credibility source
- Agent saves new findings to the memory MCP (`remember` / `ingest`) before returning

### Step 4: Report

Present findings in BLUF format:

```
## Conclusion
[1-2 sentence answer to the research question]

## Key Findings
[Numbered list of supporting facts/evidence]

## Sources
[Where each finding came from: the memory MCP or web URL]

## Gaps
[What remains unknown, if anything]
```

### Step 5: Persist

If Step 3 was skipped (existing knowledge was sufficient), save the synthesized conclusion to the memory MCP via `ingest` — the synthesis itself is new knowledge even if the inputs were not.
