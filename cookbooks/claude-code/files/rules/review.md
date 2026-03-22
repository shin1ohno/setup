---
description: "Guidelines for code review"
---

# Code Review Guidelines

When reviewing code, follow this priority order:

1. **Security** — injection, auth bypass, secret exposure, input validation
2. **Correctness** — logic errors, edge cases, error handling
3. **Readability** — naming, structure, unnecessary complexity
4. **Performance** — only when there is measurable impact

For each finding:
- State the severity (critical / warning / suggestion)
- Explain the problem concisely
- Suggest a concrete fix
