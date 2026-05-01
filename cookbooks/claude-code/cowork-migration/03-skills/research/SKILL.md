---
name: research
description: |
  Use this skill any time the user wants to research, investigate, look up, find out about, or build understanding of a topic — including product comparisons, technical questions, best practices, "what's the state of the art on X", "what do we already know about Y", "compare A and B", or "give me a deep-dive on Z". Searches Cognee (graph + chunks + summaries) and Mem0 (user context) in parallel for prior knowledge, fills gaps via web search, returns a BLUF report with sources, and persists new findings. Distinguishes existing knowledge from new findings, flags single-source claims, and detects contradictions between stores.
---

# Research Skill

Investigate a topic by searching existing knowledge stores and the web, then persist findings.

## Argument Parsing

The user's message is the research topic or question. If absent, use AskUserQuestion to clarify.

## Workflow

### Step 1: Search Existing Knowledge

Launch two background sub-agents in parallel via the Agent tool (`run_in_background: true`):

**Agent A — Cognee search** (skip silently if Cognee MCP is not connected):

- Run three query types: GRAPH_COMPLETION (relationships), CHUNKS (facts), SUMMARIES (overviews)
- `top_k=15` for broad exploration
- Topic: user's question

**Agent B — Mem0 search** (skip silently if Mem0 MCP is not connected):

- Search Mem0 for user-related context on the topic
- Topic: user's question

### Step 2: Gap Analysis and Contradiction Detection

When agents return:

1. List what is already known (from Cognee + Mem0)
2. **Contradiction check**: if Cognee and Mem0 conflict, flag explicitly and investigate which is current
3. Identify gaps — questions still unanswered
4. If no gaps, skip to Step 4

### Step 3: Web Research

Launch a research sub-agent to fill gaps:

- Provide specific gap questions as search targets
- Agent uses WebSearch and WebFetch
- **Source credibility**: tag every finding with source type (official docs / engineering blog / forum post / vendor marketing). Flag findings backed by a single low-credibility source
- Agent saves new findings to Cognee (if connected) before returning

### Step 4: Report

Present findings in BLUF format:

```
## Conclusion
[1-2 sentence answer]

## Key Findings
[Numbered list of facts/evidence]

## Sources
[Where each finding came from: Cognee / Mem0 / web URL]

## Gaps
[What remains unknown, if anything]
```

Add a `Sources:` section at the end with markdown hyperlinks if web sources are used (matches Cowork's web search citation convention).

### Step 5: Persist

If Step 3 was skipped (existing knowledge sufficed), still save the synthesized conclusion to Cognee via `cognify` — the synthesis itself is new knowledge.

## When NOT to use

- The user wants a quick factual answer that's already in Claude's training data
- The topic is clearly out of scope of any connected knowledge store and not web-searchable
- The user has already done the research and just wants implementation
