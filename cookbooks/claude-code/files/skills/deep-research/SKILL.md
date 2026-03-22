---
name: deep-research
description: 3-team parallel research. Runs web research, technical deep-dive, and critical analysis in parallel, then integrates, reviews, and produces a final report.
user-invocable: true
---

# Deep Research Skill

## Argument Parsing

Treat `$ARGUMENTS` as the research task. If omitted, use AskUserQuestion to prompt the user for input.

## Preparation: Load Personas

Read the following files using the Read tool:

1. `~/.claude/skills/takt/personas/deep-research-planner.md`
2. `~/.claude/skills/takt/personas/web-researcher.md`
3. `~/.claude/skills/takt/personas/tech-analyst.md`
4. `~/.claude/skills/takt/personas/critical-analyst.md`
5. `~/.claude/skills/takt/personas/integrator.md`
6. `~/.claude/skills/takt/personas/report-writer.md`

## Workflow

### Step 1: Plan (Research Planning)

Launch Agent tool (subagent_type: "general-purpose"):

- Persona: deep-research-planner
- Instructions:
  - Analyze and decompose the research task
  - Draft specific investigation instructions for 3 parallel teams (web research, technical deep-dive, critical analysis)
  - Write with enough specificity that each team can work independently

If there is feedback from a review (during re-planning), include the feedback in the prompt.

### Step 2: Investigate (3-Team Parallel Research)

Launch 3 Agent tools **in a single message** in parallel:

**Agent 1 - Web Research:**
- Persona: web-researcher
- Pass the "web research team instructions" from the Step 1 plan
- Execute web searches and document research

**Agent 2 - Tech Deep-dive:**
- Persona: tech-analyst
- Pass the "technical deep-dive team instructions" from the Step 1 plan
- Investigate codebase, API specs, and technical documentation

**Agent 3 - Critical Analysis:**
- Persona: critical-analyst
- Pass the "critical analysis team instructions" from the Step 1 plan
- Analyze risks, alternatives, counterarguments, and edge cases

Proceed to the next step once all 3 agents have returned results.
If any agent fails, return to Step 1.

### Step 3: Integrate (Synthesis)

Launch Agent tool:

- Persona: integrator
- Pass all 3 teams' outputs
- Instructions:
  - Extract key findings
  - Remove duplicates and identify contradictions
  - Identify gaps
  - Present preliminary conclusions

### Step 4: Review (Quality Check)

Launch Agent tool:

- Persona: integrator (from a review perspective)
- Pass the integration results from Step 3
- Instructions:
  - Evaluate responsiveness to the request, comprehensiveness, reliability, and practicality
  - Approve at 80% or higher quality

**If quality is insufficient**: return to Step 1 with feedback (maximum 3 cycles).

### Step 5: Report (Final Report)

Launch Agent tool:

- Persona: report-writer
- Pass the reviewed results from Step 4
- Instructions:
  - Write the report with BLUF (Bottom Line Up Front)
  - Include key findings, detailed analysis, risks, recommendations, and reference sources

## Final Output

Present the report to the user.
