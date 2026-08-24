---
description: "Sub-agent design principles, bulk research pattern, and tool selection guide"
---

# Sub-agent Design Principles

This file is the always-loaded summary. Long examples + origin notes are in `~/.claude/docs/sub-agents-detail.md` (NOT auto-imported — load on demand via Read tool when a section pointer matches the current task).

- 1 agent = 1 task: never give multiple roles to a single agent
- Run parallelizable tasks in parallel (Agent tool parallel calls)
- Review gate: always include a review step for important outputs
- Background first: any research task that does not block the next step must use `run_in_background: true`. This includes memory searches at conversation start, web research, and catalog lookups. The main conversation should never idle while waiting for research results — either launch background agents or continue interacting with the user

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

Detail (origin): see `~/.claude/docs/sub-agents-detail.md#parallel-stream-file-exclusivity`.

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

Detail (origin): see `~/.claude/docs/sub-agents-detail.md#destructive-operation-scope-boundary`.

## Analysis-only Agent Scope — No File Edits Without Explicit Authorization

When a sub-agent's (or workflow agent's) task is framed as **analysis, design, or review** — return a root cause, propose code, identify issues, draft a plan — it MUST NOT edit, create, or overwrite any file unless the prompt explicitly authorizes it. Returning the proposed change as text in the completion output is the correct deliverable; applying it is out of scope. (Distinct from the Destructive-Operation boundary above, which covers deletions; this covers creations and edits when the task was never meant to write at all.)

**Prompt discipline**: when the intent is analysis-only, add this sentence verbatim to the agent prompt: "Do NOT edit or create any files. Return your findings as text in the completion output only."

**Orchestrator discipline**: treat any file edits an analysis-phase agent made anyway as *proposals requiring review*, never as committed work. Before accepting them:

1. Read the modified file and diff it against origin
2. Verify the edit is correct against the FULL problem specification — not just "does it make the immediate error stop?"
3. Only then keep it; otherwise discard and apply the correct fix yourself

**Production service boundary** — when an analysis/synthesis-phase agent's task touches a RUNNING service (docker container, systemd unit, `elastic-agent`, the auto-mitamae orchestrator, any PVE LXC service), the read-only default applies EVEN IF the parent prompt omitted the verbatim sentence above. Default in these contexts:

- Read config/log files, `systemctl status`, `elastic-agent status`, `docker compose ps` — allowed
- Write config files, `systemctl restart`, `docker compose up`, `pct exec … bash -c "<service mutation>"` — NOT allowed without explicit authorization in the prompt

If the agent concludes it MUST mutate a production service to resolve an ambiguity, it surfaces the proposed change as text + stops — it does not execute. An orchestrator / auto-mitamae auto-revert is NOT a safety net: it catches the action only AFTER the service was already restarted with an untested config.

Detail (why "no immediate error" is insufficient + origins): see `~/.claude/docs/sub-agents-detail.md#analysis-only-agent-scope`.

## Agent-Team Messaging Contract — SendMessage delivery, single-send, inbox probe, shutdown

Agent-team teammates (TeamCreate / SendMessage) deliver results ONLY via `SendMessage` — a teammate's plain-text turn output does NOT reach the lead. This is the OPPOSITE of Task-tool sub-agents, whose completion text IS the deliverable: the "Analysis-only Agent Scope" sentence "Return your findings as text in the completion output only" applies to Task-tool agents ONLY — writing it in a teammate prompt discards the findings and forces a re-request round-trip.

Fan-out prompts to teammates MUST state the delivery contract: 「完了＝findings 全文を SendMessage で <lead の named agent id> 宛に 1 回だけ送る。ToolSearch select:SendMessage で schema を先にロード」.

- **Lead**: `to:"main"` is rejected by the harness as self-address — always address a named agent. Before nudging a "silent" teammate, probe your own inbox first; if a nudge is needed, send a short resend-request, NEVER the full task prompt (full-prompt resend triggers duplicate execution and multi-KB duplicate findings).
- **Worker**: on receiving an identical prompt for an already-completed task, resend the finished report — do not re-execute.
- **Lead**: after collecting a teammate's deliverable with no further work planned for it, shut the teammate down in the same turn — do not wait for the user to ask.

Mechanical backstop: `hooks/warn-background-launch-no-progress.rb` (Stop, non-blocking) also fires when a teammate's idle notification arrived with no delivered findings and no resend request by turn end — added 2026-08-23 after two teammates in one session idled silently, two months after this prose landed.

Detail (session origins): see `~/.claude/docs/sub-agents-detail.md#agent-team-messaging-contract`.

## Auto-Launched Review Agent — Dedupe + Completion by Findings Return

Auto-launched security/code-review agents (the claude.ai-side auto-review that fires on a diff — NOT a hook in this repo, so this is a behavioral rule) can double-fire on the same change and can die mid-review. Two guards:

1. **Dedupe by prompt/diff hash within a short window**: hash the review prompt (which embeds the target diff); if an identical-hash review already returned findings OR is currently in-flight within the last ~10 min, skip the re-launch. Two full reviews of a byte-identical diff are pure double-consumption — each carries full context plus the always-loaded rules.
2. **Judge "completed" by findings RETURN, never by session end**: a review counts as done ONLY when it returned findings via `ReportFindings` / `StructuredOutput`. A session that ended with zero assistant entries (never ran) or died mid-`tool_use` (no findings returned) is NOT "reviewed" — re-run it or leave a WARN. Critically, a mid-death session must NOT be treated as complete for dedupe purposes: doing so suppresses the re-fire that may be the only valid review of that diff.

Detail (origin): see `~/.claude/docs/sub-agents-detail.md#auto-launched-review-agent`.

## Review Agent Out-of-Scope Findings — Capture, Don't Drop

When a review agent (security-review, code-review) surfaces a correctness / idempotency / stale-reference finding that is outside the review's declared scope, capture it — do NOT let it evaporate into review prose that then returns `findings: []`. A security review that prose-notes "this is a correctness wart, not a security exposure" and returns an empty findings array silently drops a real, unfixed bug.

- If reporting via `ReportFindings`, include the out-of-scope finding under `category: "correctness"` (an example category the tool explicitly permits) rather than omitting it.
- Otherwise, surface it as an "Out-of-scope observations" note AND transcribe it to TODO.md in the same turn (description / reason / concrete first step; delete the entry in the resolving commit).

Detail (origin): see `~/.claude/docs/sub-agents-detail.md#review-agent-out-of-scope`.

## Fleet Status Verification — Functional Probe in the Agent Prompt

When dispatching an agent to verify health across fleet hosts, the prompt MUST name the FUNCTIONAL probe, not leave the agent to infer it. Agents default to artifact-level checks (`systemctl is-active`, `docker ps`, "process running") that return healthy even for a degraded service — producing false-positive HEALTHY reports that can close an incident prematurely. Name the per-service functional check in the prompt (data flowing, components active), not just that the process runs.

Detail (per-service artifact-vs-functional table + prompt-line example + origin): see `~/.claude/docs/sub-agents-detail.md#fleet-status-verification`.

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

Detail (origin): see `~/.claude/docs/sub-agents-detail.md#tool-availability-toolsearch`.

## Sub-agent Scratch-File Discipline

When a sub-agent's task involves writing smoke-test fixtures, stub binaries, call logs, or any temporary artifact, the launching prompt MUST pin the write location to `$TMPDIR` (or an explicit scratchpad path) — never the tracked repo tree. Sub-agents do NOT inherit the session's scratchpad path automatically; name it in the prompt. A stray untracked file left inside a tracked directory blocks the next `git pull` with "untracked working tree files would be overwritten by merge" and pollutes `git status` for every later actor. The `warn-untracked-before-pull.rb` hook is the warn-only backstop; this prompt-side rule is the prevention. Origin: 2026-07-08 — a ruby agent's fake-remind stub landed in `cookbooks/.../todo-collect/` and blocked the post-merge pull.

## Bulk Research Pattern

When collecting information from multiple sources (URLs, products, brands, categories), **proactively** (before the user asks for parallelism) split by independence — 1 agent = 1 brand / category / theme — launch all agents in background in parallel (`run_in_background: true` in one message), have each WebFetch and save findings to the memory MCP (`remember` / `ingest`), and show a live-updating progress table.

**Cited output: split collection from verification, and make source-record cross-check a named completion requirement.** Whenever agent output carries citations (evidence pages, literature reviews, research reports, competitor claims), the collecting agent must NOT also judge its own citations — give a separate agent the verification role, and write into *its* completion requirements: "confirm each PMID / DOI / URL resolves, and that the author, year, journal and title on the page match the record — not merely that the citation is plausible." Fabricated and misattributed citations are a standing failure mode that plausibility review never catches: one such verify role corrected 24 of 43 source pages, including an attribution to an author who did not write the paper and a DOI belonging to a different article, and an operator spot-check of 6 citations afterwards found zero remaining errors. Also require the verifier to leave rejected items in place with their reason, so the next run does not re-collect them.

Detail (numbered breakdown + examples): see `~/.claude/docs/sub-agents-detail.md#bulk-research-pattern`.

## Synthesis Stage — Pass Data by Path, Split the Output

A synthesis stage that merges N upstream streams fails in two ways that both look like a flaky API rather than a design error: an oversized prompt and an oversized single response.

- **Pass the aggregate by file path, never inline.** Have each upstream stream write its result to a file (or write the merged array yourself), and give the synthesis agent the PATH plus the jq/Read commands to pull out the columns it needs. Never interpolate upstream JSON or transcript text into the synthesis prompt — the prompt grows with the number of streams, so this breaks exactly when the fan-out was worth doing. Tell the agent not to `cat` the whole file either.
- **Split a large deliverable across agents or sections.** When the output is a catalog, a multi-service inventory, or a long report, assign disjoint section ranges to separate agents and concatenate, instead of asking one agent for the whole thing. Each agent then reads only the slice of data its sections need.

Symptom to recognise: the orchestrator returns `null` (or an empty string) for the synthesis step while every upstream stream succeeded, with a mid-response server error in the failure list. Resume with the data moved to a file and the output split; the upstream stages replay from cache, so only the synthesis re-runs.

Detail (origin): see `~/.claude/docs/sub-agents-detail.md#synthesis-stage-data-by-path`.

## Long-Running Tasks

When a sub-agent needs to execute a task that runs longer than a few minutes (stability tests, load tests, multi-cycle benchmarks):

- **The agent must own the loop**: the agent itself should iterate (e.g., for-loop over cycles with sleep between them), not launch a bash script in the background and terminate. When an agent launches `run_in_background: true` bash and then returns, the background process may be killed when the agent's session ends
- **Never delegate monitoring to a detached script**: if the task requires periodic checks, error recovery, or metric collection, the agent must stay alive to perform these — a fire-and-forget bash script cannot recover from failures or report intermediate results
- **Timeout awareness**: if a task exceeds the agent's practical execution window, break it into phases — the agent completes phase 1, reports results, and the parent schedules phase 2

## Background Agent Progress Tracking

**A launch and its observation loop are ONE unit.** Any background start expected to exceed ~10 min (workflow batch, Ultraplan, remote research, multi-agent fan-out) must, in the SAME turn, (a) state the expected duration in one line and (b) establish the observation loop — a `Monitor`, an until-loop, or a `ScheduleWakeup`. A launch with no observation loop is prohibited, and closing the turn with "完了時に通知が来ます" is a violation: a completion notification is not a reliable terminal signal (sub-agents die silently on rate-limit / `Connection closed`). Answer a user's "status?" / "止まってませんか" with concrete progress — done N/M, most-recent completed stream, last-activity time — before resuming any other work. Observe before you kill: no `TaskStop` until tool activity on the observation source is zero across 2 consecutive probes, and read the transcript tail to classify stuck vs recovering first.

**Mechanical backstop**: `hooks/warn-background-launch-no-progress.rb` (Stop, non-blocking) fires a reminder when a turn ends after a `Task` / `Workflow` / `run_in_background` launch with no observation call and no progress line since. It exists because this section — already spelled out in full since 2026-07 — still fired in 5 separate sessions over the following 30 days (2026-07-28〜08-05: 「SubAgent動いてなくないですか？」「続けて。workflowが止まってるように見える」「終わってませんか？」「左のpaneのAgentの状況わかる？」「続けて、SubAgentの様子も確認」). Prose alone is measurably insufficient here.

Deadline guide, stall-detection mechanics, and the re-launch ban: see `~/.claude/docs/sub-agents-detail.md#background-agent-deadline-tracking`.

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

Detail (origin): see `~/.claude/docs/sub-agents-detail.md#60-second-rule`.
