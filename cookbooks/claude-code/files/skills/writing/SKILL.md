---
name: writing
description: Document creation and proofreading based on Pyramid Principle + marginal utility. Supports both new creation and editing of existing text.
user-invocable: true
---

# Writing Skill

## Argument Parsing

Treat `$ARGUMENTS` as the task content. If omitted, use AskUserQuestion to prompt the user for input.

## Preparation: Load Personas

Read the following 2 files using the Read tool:

1. `~/.takt/personas/document-writer.md` - Writer persona
2. `~/.takt/personas/marginal-utility-editor.md` - Editor persona

## Workflow

Execute 3 steps sequentially. Each step is delegated to an independent agent via the Agent tool.

### Step 1: Plan (Structure Design)

Launch Agent tool (subagent_type: "general-purpose"):

- Persona: include document-writer content in the prompt
- Instructions:
  - Analyze the task and determine mode (new creation or proofreading)
  - Design structure based on Pyramid Principle (conclusion → arguments → details)
  - Identify target audience and purpose
  - Decide document format (short / medium / long)

### Step 2: Write (Drafting)

Launch Agent tool:

- Persona: include document-writer content in the prompt
- Pass the structure design from Step 1 as prior context
- Instructions:
  - Write the document following the structure design
  - State the conclusion first
  - Use narrative prose (minimize bullet points)
  - Use concrete numbers and facts instead of adjectives and adverbs
  - Output the completed draft only

### Step 3: Edit (Marginal Utility Editing)

Launch Agent tool:

- Persona: include marginal-utility-editor content in the prompt
- Pass the draft from Step 2
- Instructions:
  - Apply marginal utility test (evaluate each sentence's reason to exist)
  - Check structure (Pyramid Principle)
  - Check expression (adjectives → numbers, passive → active voice)
  - Output editing report + edited draft

### Step 3 Decision

If the editor determines "revision needed", return to Step 1 with the editor's feedback included.
Maximum 3 cycles. Upon reaching 3 cycles, output the best draft at that point as the final version.

## Final Output

Present the editor-approved draft (or the final draft upon reaching 3 cycles) to the user.
