---
type: llm
focus: trace
weight: 1
---

The final message reports status in the references/report.md layout: inside a code fence, a first line starting with `▶`, then only non-empty sections from 要対応 / 待ち / 実行中 / 中断 / 完了 in that order, one line per task that starts with the task id's first 8 characters (058c… and 1bd6…) and whose text starts with one of `Q:` `dialog:` `done:` `error:` `on <who>:` `step i/n:` `next:`
