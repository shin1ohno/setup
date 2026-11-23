---
max_turns: 30
timeout_seconds: 900
allowed_tools: [Read, Glob, Grep, Skill, Write, Edit, Bash, AskUserQuestion]
---

<task-notification>Background command "Required checks for PR 42 (task 183c009de9f44a75): gh pr checks 42 --watch --required" completed (exit code 0). Output:
All checks were successful
0 cancelled, 0 failing, 3 successful, 0 skipped, and 0 pending checks

   NAME   DESCRIPTION  ELAPSED  URL
✓  build               1m2s     https://github.example.invalid/acme/eval-repo/actions/runs/7001/job/1
✓  lint                21s      https://github.example.invalid/acme/eval-repo/actions/runs/7001/job/2
✓  test                2m40s    https://github.example.invalid/acme/eval-repo/actions/runs/7001/job/3
</task-notification>

Environment: you are this conversation's Chief of Staff controller; the chief-of-staff skill was activated earlier in this conversation. The verified owner key is `herdr:evalsock#w1:p1` (Herdr 1 session `evalsock`, controller pane `w1:p1`). Caller verification already ran in this session; do not run it again. The ledger is ./state: run every ledger command as `COS_STATE_DIR=$PWD/state python3 <skill-dir>/scripts/tasks.py ...` with `--owner 'herdr:evalsock#w1:p1'`, where `<skill-dir>` is the chief-of-staff skill's base directory. Task 183c009de9f44a75's envelope was received earlier; its worker cos-183c009de9f44a75-1 is settled. Do not run `herdr`, `hc`, `gh`, `git push`, Linear tools or MCP tools, and do not start background jobs that call them; write "Would run: ..." instead, and say "in the background" for a command you would start in the background. The task checkout /tmp/eval-repo does not exist on this machine, so write "Would run: ..." for commands in it too. Read-only files stand in for command output: `gh pr view 42 --json number,url,state,mergeStateStatus,reviewDecision,headRefName,baseRefName,files,statusCheckRollup` is ./gh-pr-view.json, and `gh auth status` is ./gh-auth-status.txt. Worker session logs are not available here.

Input files: state/, gh-pr-view.json, gh-auth-status.txt
