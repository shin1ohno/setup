---
name: feature-parity
description: Compare an implementation against a reference implementation, or against a spec (SPEC.md, ADR, plan file), and produce a gap or discrepancy analysis
user-invocable: true
---

# Feature Parity Audit Skill

## Purpose

Exhaustively compare the current project's implementation against a reference implementation to identify feature gaps, behavioral differences, and missing APIs.

**Spec mode**: when the reference is a document (a `SPEC.md`, an ADR, a plan file) rather than code, follow "Spec mode" at the end instead of Steps 1-6.

## Workflow

### Step 1: Identify Reference

Ask the user to specify:
- Path to the reference implementation (e.g., `/home/shin1ohno/ManagedProjects/node-roon-api/`)
- Path to the current implementation (default: current working directory)

### Step 2: Parallel Exploration

Delegate to 2 read-only exploration sub-agents in parallel if sub-agents are available (otherwise run the two audits one after another in this session; Claude Code: Explore agents via the Agent tool):

**Agent 1: Reference Implementation Audit**
- Read every source file in the reference
- Inventory every public API, method, event, callback, option, type
- Document behavioral details: error handling, edge cases, lifecycle

**Agent 2: Current Implementation Audit**
- Read every source file in the current project
- Inventory every public type, method, trait, function
- Document test coverage and verified behaviors

### Step 3: Gap Analysis

Compare the two inventories and produce a table with columns:
- Feature name
- Reference: present/absent
- Current: present/absent
- Priority: high/medium/low
- Notes

### Step 4: Present Results

Group gaps by priority:
- **High**: Features required for SDK consumers (missing APIs, broken contracts)
- **Medium**: Completeness improvements (missing services, edge cases)
- **Low**: Nice-to-have (logging, browser support, convenience methods)

### Step 5: User Decision

Ask the user to choose which gaps to address, allowing multiple selections (use the question tool if available, otherwise write numbered options in the message body; Claude Code: AskUserQuestion with multiSelect / Codex: request_user_input).

### Step 6: Plan

For selected gaps, present an implementation plan and get approval before implementing (Claude Code: plan mode).

## Spec mode

Validate an implementation against its spec. The spec is the baseline; deviations are measured from it. This pass reports and records — it fixes no code.

1. **Read the spec in full** and list every deliverable: each requirement, field, behavior, error case, config key, and acceptance criterion.
2. **Check each one against the code** (file:line). Be exhaustive: an area that "looks fine" still gets checked. Group a mismatch that cascades through several files into one discrepancy listing all locations.
3. **Record** a `### Discrepancies` subsection under the spec's `## Current Status`, one line each, starting as pending:

   ```
   ### Discrepancies
   - **<short name>** — spec says <X> (§<section>), impl does <Y> (`path:line`). Resolution: pending
   ```

4. **Ask the user per batch** of related discrepancies (question tool if available; Claude Code: AskUserQuestion / Codex: request_user_input), stating what the spec says, what the code does, and whether it is missing, extra or divergent. Options:
   - Spec is correct — implementation needs fixing
   - Implementation is correct — spec needs updating
   - Intentional deviation — record it in the spec's Updates with the reason
   - Needs further discussion
5. **After each batch**, update each line's `Resolution:` in the spec. Do not guess intent and do not fix code in this pass; the fixes are a separate, planned change.
6. **Report clean results too**: list the spec areas checked that matched, so the reader knows they were checked rather than skipped.
