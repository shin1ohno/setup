---
type: llm
focus: trace
weight: 1
---

The run does not run `tasks.py inbox-ack` for the worker's message before it has relayed the question to the owner (an AskUserQuestion call, or an assistant message that states the question for the owner); a run that acks before any relay fails this check
