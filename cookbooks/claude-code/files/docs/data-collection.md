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

## Live / Time-Varying Data Research (prices, inventory, availability, deadlines)

When researching time-varying data that feeds a user's money decision (booking, purchase) — prices, stock, seat availability, cancellation deadlines:

1. **Map confirmed conditions 1:1 to the search**: mirror every settled parameter (party breakdown, nights, dates, room count) straight into the search, and attach the search conditions to any figure you present (e.g. "adults 3 + child 1 / 6 nights / 7/12–18"). Never present a number obtained under different conditions than the user confirmed.
2. **Expand relative-date claims against the calendar**: statements like "free until X days before departure" or "date Y is peak" must be resolved to concrete dates and checked against today (`date +%F`) and the holiday calendar before you assert them. Always confirm the deadline has not already passed.
3. **No exhaustiveness claims without a source**: never assert "cheapest / all failed / does not exist" from inference or static-page results. Enumerate the providers actually checked, mark each as live vs inferred, name what was NOT checked, and downgrade the claim to "cheapest within what I checked".
4. **Default to a LIVE fetch for money-moving numbers**: any figure backing a booking/purchase recommendation defaults to a live fetch (claude-in-chrome or equivalent). If no live-fetch channel is available this session, state explicitly that the number is NOT a live quote and do not use an inferred/recalled value as the basis for an action recommendation.

Origin: 2026-06-29 Okinawa trip package — searched the confirmed "adults 3 + child 1" under the wrong party size and presented it (user: "人数とか日程とか間違えてませんか？"); presented "free until 21 days before" on 6/29 when the 6/21 deadline had already passed; declared "packages all failed" moments before the user found a ¥470k counterexample. Four user corrections in one session.
