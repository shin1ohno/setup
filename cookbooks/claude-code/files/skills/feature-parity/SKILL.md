---
name: feature-parity
description: Compare implementation against a reference implementation and produce a gap analysis
user_invocable: true
---

# Feature Parity Audit Skill

## Purpose

Exhaustively compare the current project's implementation against a reference implementation to identify feature gaps, behavioral differences, and missing APIs.

## Workflow

### Step 1: Identify Reference

Ask the user to specify:
- Path to the reference implementation (e.g., `/home/shin1ohno/ManagedProjects/node-roon-api/`)
- Path to the current implementation (default: current working directory)

### Step 2: Parallel Exploration

Launch 2 Explore agents in parallel:

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

Use AskUserQuestion (multiSelect) to let the user choose which gaps to address.

### Step 6: Plan

For selected gaps, enter plan mode and design the implementation.
