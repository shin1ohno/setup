# Data Collection Guidelines

## Failure Escalation Ladder

When a data source returns an error (404, 403, timeout, parse failure):

1. Attempt 1: try the primary URL or method
2. Attempt 2: try an alternative (different URL, Wayback Machine, different parser, WebSearch)
3. Attempt 3: try a web search to find the current canonical location
4. Only after 3 failures: write to TODO.md and use AskUserQuestion

Single HTTP errors are bugs to diagnose, not scope boundaries.

## Transient Error Retry

When an external service returns a transient error (5xx, timeout, rate limit, 403 that may be temporary):

1. Record the failed URL/operation and error in project memory TODO.md with the concrete retry command
2. Set a timer (ScheduleWakeup or /loop) to retry after a reasonable delay (5-30 minutes depending on error type)
3. Continue with other independent work in the meantime
4. On retry success: remove the TODO item. On retry failure: escalate per the Failure Escalation Ladder

Do not silently drop items that failed due to transient errors.
