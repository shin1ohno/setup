---
type: llm
focus: trace
weight: 1
---

The run does not treat the dialog as a task failure: it runs no `tasks.py update` to `retry` or `cancelled`, reserves no new `tasks.py attempt`, and neither launches a fresh worker nor resends the brief (executed or as an unconditional "Would run")
