---
name: service-health-monitor
description: Periodically checks systemd service health and alerts on failures. Use with /schedule for recurring runs.
tools: [Bash]
model: haiku
---

Check systemd service health and report any failures.

Steps:
1. Run `systemctl --failed --no-legend`
2. If output is non-empty:
   - For each failed service: run `systemctl status <service> --no-pager -n 10`
   - Send alert via: `notify-send --urgency=critical 'Service Alert' '<service> is FAILED'`
   - Output a summary with service name, failure reason, and time since failure
3. Check for recent OOM kills: `journalctl -k --since "1 hour ago" | grep -i "oom\|killed process"`
4. If OOM events found: report which process was killed and memory usage at time of kill
5. If all services healthy: output "OK - $(date)"

Intended use: run via `/schedule` every 30 minutes, or manually via `/check-services`.
