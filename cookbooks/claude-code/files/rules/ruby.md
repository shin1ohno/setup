---
globs: "*.rb"
---

# Ruby Code Guidelines

- Prefer explicit over implicit — avoid magic methods and meta-programming unless clearly beneficial
- Use guard clauses to reduce nesting
- Follow existing project conventions (indentation, naming, etc.)
- When working with mitamae DSL: use `not_if` / `only_if` for idempotency checks
- Prefer symbols over strings for hash keys in DSL code
- mitamae runs without sudo. Never use `owner node[:setup][:system_user]` on file/remote_file resources — it triggers an internal `sudo chown` that fails without a terminal. Instead, stage files in user space (`node[:setup][:root]`) and use `execute` with explicit `sudo cp` to place them in system directories

## Auth-check gate must match the cookbook's actual invocation profile

When writing a `require_external_auth` (or any auth-check gate) in a cookbook, the `check_command` MUST use the exact same `--profile` and `--region` (and any other identity-affecting flags) as the cookbook's actual operations. A gate that passes against a different identity is a false gate — it lets the cookbook proceed and then silently fail at the real call.

**Validation question**: "if the named profile is absent, does my gate fail?" If the answer is "depends on whether default profile is present", the gate is wrong.

**Stronger pattern** — make the check_command attempt the actual resource read the cookbook will need:

```ruby
device_ssm_check = "aws ssm get-parameter --name /ssh-keys/devices/#{host}/private " \
                   "--profile #{aws_profile} --region #{aws_region} > /dev/null 2>&1"
require_external_auth(check_command: device_ssm_check, ...)
```

vs the false gate:

```ruby
require_external_auth(check_command: "aws sts get-caller-identity", ...)  # passes against ANY default profile
```

This rule exists because the 2026-04-25 neo bootstrap session: ssh-keys cookbook gated on `aws sts get-caller-identity` (no `--profile`) but invoked SSM with `--profile sh1admn`. neo had only `default` configured → gate passed → every fetch_ssm silently failed → cascade through dot-tmux, managed-projects, speedtest-cli before the user noticed. Fixed in cc2f989 by switching to a profile-aware actual-SSM-read gate.

## STDIN.tty? guard before any blocking STDIN read

Any Ruby cookbook helper (or any mitamae recipe code) that reads from STDIN MUST check `STDIN.tty?` before entering a blocking read or loop. In non-TTY contexts (CI, agent-driven runs, dry-runs over ssh without `-t`), `STDIN.gets` returns `nil` immediately — and `nil` is not a useful loop-exit signal.

```ruby
# WRONG — infinite loop in CI
loop do
  result = run_command(check, error: false)
  return if result.exit_status == 0
  STDIN.gets  # nil immediately on non-TTY → loop never blocks → spin forever
end

# RIGHT — fail-soft skip in non-TTY
unless STDIN.tty?
  MItamae.logger.warn("[bootstrap] non-TTY context — skipping interactive gate")
  yield if block_given?
  return
end
```

Never rely on `gets` returning nil as a loop-exit signal.

This rule exists because the 2026-04-25 bootstrap-robustness PR shipped a `require_external_auth` helper that hung 3 CI runs for 1+ hour each before manual cancellation. The bug was visible only in CI — local TTY runs worked fine, hiding it. Fixed by adding the TTY guard before the loop.
