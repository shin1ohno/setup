---
name: research
description: Research a topic using Cognee, Mem0, and web search. Persists findings automatically.
user-invocable: true
argument-hint: "[topic or question]"
---

# Research Skill

## Purpose

Investigate a topic by searching existing knowledge stores (Cognee, Mem0) and the web, then persist findings automatically.

## Argument Parsing

`$ARGUMENTS` is the research topic or question. If omitted, use AskUserQuestion to ask what to research.

## Workflow

### Step 1: Search Existing Knowledge

Launch 2 `researcher` agents **in parallel** via the Agent tool (both with `run_in_background: true`):

**Agent A — Cognee search:**
- Search Cognee with 3 query types: GRAPH_COMPLETION (relationships), CHUNKS (facts), SUMMARIES (overviews)
- Use `top_k=15` for broad exploration
- Topic: `$ARGUMENTS`

**Agent B — Mem0 search:**
- Search Mem0 for any user-related context on the topic
- Topic: `$ARGUMENTS`

### Step 2: Gap Analysis and Contradiction Detection

When both agents return, synthesize their results:

1. List what is already known (from Cognee + Mem0)
2. **Contradiction check**: if Cognee and Mem0 return conflicting information, flag the contradiction explicitly and investigate which is current
3. Identify gaps: what questions remain unanswered?
4. If no gaps exist, skip to Step 4

### Step 3: Web Research

Launch a `researcher` agent to fill identified gaps:

- Provide the specific gaps as search targets
- Agent uses WebSearch to find sources, WebFetch to extract details
- **Source credibility**: tag each finding with source type (official docs / engineering blog / forum post / vendor marketing). Flag findings that rely on a single low-credibility source
- Agent saves new findings to Cognee/Mem0 before returning

### Step 4: Report

Present findings in BLUF format:

```
## Conclusion
[1-2 sentence answer to the research question]

## Key Findings
[Numbered list of supporting facts/evidence]

## Sources
[Where each finding came from: Cognee, Mem0, or web URL]

## Gaps
[What remains unknown, if anything]
```

### Step 5: Persist

If Step 3 was skipped (existing knowledge was sufficient), save the synthesized conclusion to Cognee via `cognify` — the synthesis itself is new knowledge even if the inputs were not.
