---
description: "RemoteTrigger API field reference and design patterns — loaded when creating scheduled triggers"
---

# RemoteTrigger API Field Reference

When creating scheduled triggers via the RemoteTrigger tool:

- Schedule field: `cron_expression` (NOT `cron` or `schedule`)
- No top-level `prompt` or `description` field — the prompt goes inside `job_config.ccr.events[].data.message.content`
- Required top-level fields: `name`, `cron_expression`, `job_config`
- Optional top-level fields: `enabled`, `mcp_connections`
- The `job_config.ccr` object requires: `environment_id`, `session_context` (with `model`, `sources`, `allowed_tools`), `events`
- Each event needs a fresh lowercase v4 UUID in `events[].data.uuid`
- Cron expressions are in UTC — convert from user's local timezone (Asia/Tokyo = UTC+9)

## Model Selection

- **opus**: research-heavy triggers (domain research, web synthesis, multi-source analysis). Match the agent's declared model — `domain-researcher` specifies opus
- **sonnet**: well-scoped operational tasks (healthcheck, load-test, single-repo audit)

## Design Principles

- **1 trigger = 1 task**: split research and action into separate triggers. A research trigger saves findings to Cognee; an action trigger reads Cognee and produces a PR
- **Chain via time offset**: if trigger B depends on trigger A's output (via Cognee), schedule B 3-4 hours after A on the same day
