---
type: llm
focus: trace
weight: 1
---

Before its first AskUserQuestion call (or, if it never calls AskUserQuestion, before the final message), the run gives worker cos-841b114c257a4b11-1 its pre-approved next step, executed or written as "Would run": a `herdr agent prompt` to that worker, or a resume of it through `tasks.py attempt --reuse-agent`, telling it to push fix/flaky-retry with `git push origin fix/flaky-retry` and open a draft PR
