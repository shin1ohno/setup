---
description: "Sub-agent design principles, bulk research pattern, and tool selection guide"
---

# Sub-agent Design Principles

- 1 agent = 1 task: never give multiple roles to a single agent
- Run parallelizable tasks in parallel (Agent tool parallel calls)
- Review gate: always include a review step for important outputs
- Background first: any research task that does not block the next step must use `run_in_background: true`. This includes Cognee/Mem0 searches at conversation start, web research, and catalog lookups. The main conversation should never idle while waiting for research results — either launch background agents or continue interacting with the user

## Parallel Stream File-Exclusivity Declaration

When launching 3+ sub-agents in parallel over the same repository, declare which files each stream may write to BEFORE launching the batch. Streams that share file ownership produce merge conflicts that cost a full PR cycle to resolve.

**Pre-launch checklist**:

1. List planned file edits per stream (in the prompt body)
2. Cross-reference: does the same file appear in 2+ streams' scopes?
3. If yes, choose explicitly:
   - **Serialize**: stream B waits for stream A to merge, then rebases
   - **Merge into one stream**: combine the two scopes into one agent
   - **Split the file**: split the cookbook / module so each stream owns a distinct file (e.g., `cookbooks/elastic-agent/files/elastic-agent.linux.yml.tmpl` vs `elastic-agent.darwin.yml.tmpl`)
4. State the exclusivity decision in each stream's prompt: "You will write to FILES X, Y, Z. DO NOT modify any file under cookbooks/foo/ — Stream <name> owns it."

This rule exists because the 2026-05-09 ADR-0005 Phase 4 session launched Stream P (Linux Elastic Agent) and Stream Q (macOS Elastic Agent) in parallel without declaring file ownership. Both independently created `cookbooks/elastic-agent/default.rb`. Stream P merged first (PR #277), Stream Q's PR #276 hit a merge conflict that required Stream Z to spawn for rebase + cross-platform branching (PR #276 second-merge cycle). One full PR cycle wasted.

## Sub-agent Destructive-Operation Scope Boundary

When instructing a sub-agent via Agent tool, explicitly state whether it may delete, rename, or overwrite existing artifacts not mentioned in its task description. **Default assumption: NO deletions of existing artifacts outside the declared scope.**

If the parent prompt does not say "you may delete X", the sub-agent must:

1. Surface the proposed deletion in its completion report
2. Send `SendMessage` to parent BEFORE executing if the deletion blocks completion
3. Stop and wait for explicit authorization

Applies to:

- **Kibana saved objects** (data views, dashboards, lens, search) created by predecessor PRs
- **Files in `~/deploy/` or `/var/lib/`** that the sub-agent did not create
- **Git-committed files** that pre-date the sub-agent's branch
- **System services** (`systemctl disable`, `systemctl mask`)
- **Database tables / collections / indices**
- **Cloud resources** (S3 buckets, IAM users, KMS keys)

This rule exists because the 2026-05-09 ADR-0005 Phase 5 Stream N "rtx-overview-v2 layout adjustment" task autonomously interpreted "consolidate dashboards" as authorization to delete Phase 5 (PR #238) saved objects (rtx-discover, top-src lens, top-dst-port lens, rtx-overview-min). The harness blocked the push but the in-stream deletions had already happened. Push was deferred indefinitely awaiting user judgment. The deletion was outside the original "build rtx-overview-v2 dashboard" task scope.

## Analysis-only Agent Scope — No File Edits Without Explicit Authorization

When a sub-agent's (or workflow agent's) task is framed as **analysis, design, or review** — return a root cause, propose code, identify issues, draft a plan — it MUST NOT edit, create, or overwrite any file unless the prompt explicitly authorizes it. Returning the proposed change as text in the completion output is the correct deliverable; applying it is out of scope. (Distinct from the Destructive-Operation boundary above, which covers deletions; this covers creations and edits when the task was never meant to write at all.)

**Prompt discipline**: when the intent is analysis-only, add this sentence verbatim to the agent prompt: "Do NOT edit or create any files. Return your findings as text in the completion output only."

**Orchestrator discipline**: treat any file edits an analysis-phase agent made anyway as *proposals requiring review*, never as committed work. Before accepting them:

1. Read the modified file and diff it against origin
2. Verify the edit is correct against the FULL problem specification — not just "does it make the immediate error stop?"
3. Only then keep it; otherwise discard and apply the correct fix yourself

**Why "no immediate error" is insufficient**: an agent fixing a collection/serialization bug in a typed framework (Terraform provider, GraphQL resolver, protobuf/JSON codec) may eliminate the observable crash while introducing a subtler invariant violation — wrong list order, missing element, schema mismatch — that fails differently on a different code path. An adversarial verifier that only checks "did the panic go away?" misses it; it must check the framework's actual contract (e.g. for a Terraform list of a Required attribute, the applied value must equal the plan element-by-element in order and count).

This rule exists because the 2026-05-31 terraform-provider-rtx session ran "analysis" workflow agents with full tool access. The dns_server-panic agent edited resource.go and created a test (out of scope) and produced a fix that stopped the nil-pointer panic but appended unmatched entries at the END of the reordered list — re-triggering "Provider produced inconsistent result after apply" because query_pattern is Required and must match plan order. The adversarial Verify phase accepted it; the parent session's independent source review caught it and replaced it with a plan-fallback.

## Tool Availability — ToolSearch Before Claiming Unavailable

A sub-agent that cannot find a named tool (`SendMessage`, `EnterPlanMode`, `AskUserQuestion`, any skill, any MCP tool) MUST call `ToolSearch` with the tool name before reporting the constraint to the parent session. Tools may be deferred-loaded, registered under a slightly different name, or behind a search index — they exist in many sessions even when not visible in the initial tool catalog.

Sequence:

1. Try `ToolSearch("select:<tool_name>")` for direct match
2. Try `ToolSearch("<keyword>")` for fuzzy match
3. Only if both return no result, escalate via the available channels:
   - SendMessage to parent (if reachable)
   - Embed the blocker in the completion output
   - Mark the task partially-complete + describe what was achieved

Parent prompts for sessions involving deferred tools should explicitly include: "If a tool appears unavailable, call `ToolSearch('<tool>')` before reporting the blockage." For sub-agent prompts that depend on `SendMessage`, `EnterPlanMode`, or skill invocation, name the ToolSearch query directly: "ToolSearch with `select:SendMessage` to load the SendMessage schema."

This rule exists because the 2026-05-09 ADR-0005 Phase 4 Stream O blocked itself reporting "no SendMessage tool available" / "no EnterPlanMode tool available" — both reachable via ToolSearch. The stream consumed a slot for ~60 seconds and produced no output. The Fleet Server work was re-routed via parent-session SendMessage broadcasts, but Stream O's idle slot was wasted.

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

**Active scanning**: when noise is in the output, explicitly grep for real errors instead of just "not noticing them at the bottom". After any Bash invocation with noisy output, scan for `error`, `Error`, `ERROR`, `fatal`, `failed`, `FAILED`, `permission denied`, `cannot`, `not found` (only after the noise block), `✗`, `❌`. Real errors tend to cluster at the end of output AFTER the noise, so tail-inspection is where mistakes happen — prefer `grep -iE "error|fatal|failed|denied"` on the full output over `| tail`.

## Long-Running Tasks

When a sub-agent needs to execute a task that runs longer than a few minutes (stability tests, load tests, multi-cycle benchmarks):

- **The agent must own the loop**: the agent itself should iterate (e.g., for-loop over cycles with sleep between them), not launch a bash script in the background and terminate. When an agent launches `run_in_background: true` bash and then returns, the background process may be killed when the agent's session ends
- **Never delegate monitoring to a detached script**: if the task requires periodic checks, error recovery, or metric collection, the agent must stay alive to perform these — a fire-and-forget bash script cannot recover from failures or report intermediate results
- **Timeout awareness**: if a task exceeds the agent's practical execution window, break it into phases — the agent completes phase 1, reports results, and the parent schedules phase 2

## Background Agent Deadline Tracking

When launching a background sub-agent (foreground Agent, Ultraplan, remote research) for planning or research, set an internal deadline and remember to check it:

- Research / codebase audit: **15 min**
- Plan-level analysis (Ultraplan, multi-repo design): **30 min**
- Large multi-repo audit or domain research: **60 min**

If the deadline passes without a completion notification, do NOT wait silently. Escalate in the next user-facing turn:

1. State the timeout explicitly: e.g. "Ultraplan が 35 分経過しても未完了です"
2. Offer concrete alternatives via AskUserQuestion:
   - wait longer (specify minutes)
   - restart with a narrower scope
   - proceed with available information without the agent's output

Do not re-launch the same agent with the same prompt expecting a different result. If the agent silently fails once, the second attempt usually fails the same way — instead narrow the scope or switch tools.

This rule exists because the 2026-04-23 iOS session had two consecutive Ultraplan failures (one user-stopped after ~15 min; one timed out silently at 90 min). Both required the user to notice the silence and manually restart. Explicit deadlines with escalation via AskUserQuestion would have surfaced the failure at the first 30 min mark.

## Tool Selection Guide

| Situation | Tool |
|-----------|------|
| One-off research / exploration | Agent tool (Explore) |
| Simple code search | Glob / Grep directly |
| 3+ step non-standard task | /plan → implement |
| 2+ independent research tasks | Background sub-agents (parallel) |
| Multi-brand/category survey | 1 agent per category (background) |

## 60-Second Rule for Inline Commands

Any single Bash command or pipeline expected to run for more than 60 seconds MUST be launched inside a background sub-agent (foreground Agent with `run_in_background: true`, OR `Bash` with `run_in_background: true` if simple). The main conversation must remain interactive while the command runs — never block a turn waiting on a multi-minute compile/build/apply.

Commands that always qualify:

- `docker compose up --build` / `docker build` on any non-trivial service
- `cargo install <crate>` (fresh dep graph compile) or `cargo build --release` on large workspaces
- `terraform apply` on anything beyond a trivial single-resource plan
- `npm run build` for Next.js / Vite production builds
- `mitamae local <role>.rb` on a role that compiles anything from source
- Any test suite that has previously taken >60s in prior sessions

Pattern: launch the sub-agent with `run_in_background: true`, emit one short user-facing line ("Deploy in background, waiting for completion notification"), and continue interacting with the user. Feed results back when the completion notification arrives. Multiple such tasks can and should run in parallel when independent.

Anti-pattern (caught in the 2026-04-23 weave session): attempting `docker compose up -d --build` inline as a foreground `Bash` call. The user corrected with "そういう時間がかかるタスクは SubAgent でやって" — this rule codifies that correction.
