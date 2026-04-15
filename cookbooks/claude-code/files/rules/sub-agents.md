---
description: "Sub-agent design principles, bulk research pattern, and tool selection guide"
---

# Sub-agent Design Principles

- 1 agent = 1 task: never give multiple roles to a single agent
- Run parallelizable tasks in parallel (Agent tool parallel calls)
- Review gate: always include a review step for important outputs
- Background first: any research task that does not block the next step must use `run_in_background: true`. This includes Cognee/Mem0 searches at conversation start, web research, and catalog lookups. The main conversation should never idle while waiting for research results — either launch background agents or continue interacting with the user

## Bulk Research Pattern

When collecting information from multiple sources (URLs, products, brands, categories), **proactively** apply this pattern (propose and execute before the user asks for parallelism):

1. **Split by independence**: divide targets so each agent's work is self-contained — 1 agent = 1 brand, category, or theme
2. **Launch all agents in background in parallel**: use `run_in_background: true` for all agents in a single message
3. **Each agent's responsibility**: WebFetch reviews → fetch specs from manufacturer sites → save to Cognee via cognify
4. **Progress reporting**: show a progress table with agent status (researching... / **done**) and update it as each agent completes

```
Example: "Save all reviews from this page" → launch sub-agents per category in background
Example: "Look up all reviews for this brand" → 1 agent per brand in background
Example: "Find bindings for this board" → 1 agent per brand group in background
```

## Agent Self-Recovery

Sub-agents should handle predictable errors autonomously before escalating to the user:

- **Library fallback**: if a Python module is unavailable (e.g., `requests`), switch to stdlib alternatives (`urllib.request`, `json`, `http.client`)
- **Extraction fallback**: if PyMuPDF returns empty text from a PDF, escalate to Vision API (page→PNG→Claude vision)
- **API fallback**: if REST API returns unexpected results, try the equivalent MCP tool
- **Escalation threshold**: only report to user after 2+ alternative approaches have been attempted and failed

This principle enables parallel agents to complete independently without blocking on user input for recoverable errors.

### Shell Init Noise

If Bash commands produce repeated `zsh: command not found: -e` or similar shell init noise, the cause is a `.zshrc` that interprets literal flags as commands. This is cosmetic — ignore the noise lines and parse only the actual command output that follows.

## Tool Selection Guide

| Situation | Tool |
|-----------|------|
| One-off research / exploration | Agent tool (Explore) |
| Simple code search | Glob / Grep directly |
| 3+ step non-standard task | /plan → implement |
| 2+ independent research tasks | Background sub-agents (parallel) |
| Multi-brand/category survey | 1 agent per category (background) |
