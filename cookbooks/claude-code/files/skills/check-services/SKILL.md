---
name: check-services
description: Check systemd service health on the Linux server and report any failed or degraded units
user-invocable: true
allowed-tools: ["Bash"]
---

# Check Services Skill

## Purpose

Detect failed or degraded systemd services before the user notices an outage.

## Workflow

1. Run `systemctl --failed --no-legend` to list all failed units
2. Run `systemctl list-units --state=degraded --no-legend` to list degraded units
3. For each failed unit, run `systemctl status <unit> --no-pager -n 20` to get recent logs
4. Check uptime of critical services: roonserver, docker, any unit in the failed list
5. Check for recent OOM kills: `journalctl -k --since "1 hour ago" | grep -i "oom\|killed process"`

## Report Format

| Service | Status | Since | Last Error |
|---------|--------|-------|------------|
| ...     | ...    | ...   | ...        |

If no failed services: output "All monitored services are running."

## Critical Services to Always Check

- roonserver
- docker (if present)
- Any service with OOMKilled in recent journal
