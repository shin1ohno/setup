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

## Mitamae evaluation model — top-level Ruby is compile-time

mitamae loads every recipe as Ruby (compile phase) before running any resource (converge phase). All top-level Ruby control flow (`if`, `unless`, `case`, plain method calls) executes at compile time, so any state check that depends on a side effect of a preceding `execute` / `remote_file` / `file` resource will see the **pre-converge** state.

The trap looks like this:

```ruby
# WRONG — `if` runs at compile time, before execute creates temp_path
execute "generate config" do
  command "bash gen.sh #{temp_path}"
end

if File.exist?(temp_path)            # always false on a clean run
  remote_file output_path do
    source temp_path                  # this resource never gets declared
  end
  file temp_path do
    action :delete
  end
end
```

On a clean machine the `remote_file` and `file` resources are never added to the resource collection, so the deploy + cleanup never fires. On a second run, `temp_path` happens to exist from the first run's execute, the `if` evaluates true at compile time, and the deploy finally happens — leading to the false impression that the cookbook "needs 2-3 mitamae passes to converge".

Same shape applies whenever the gate file is produced by an upstream cookbook in the same run: `if File.exist?("#{node[:setup][:home]}/.local/bin/claude")` evaluated at the top of `cookbooks/notion/default.rb` runs before `cookbooks/claude-code` has installed the binary.

**Two correct patterns:**

1. **Single-pipeline `execute`** (preferred when generate / install / cleanup are all shell-ish):

   ```ruby
   execute "generate and deploy config" do
     command <<~CMD.strip
       set -euo pipefail
       bash gen.sh #{temp_path}
       install -m 644 #{temp_path} #{output_path}
       rm -f #{temp_path}
     CMD
   end
   ```

2. **String / Proc `only_if` at the resource level** (when you need separate resources, e.g. for `notifies`):

   ```ruby
   remote_file output_path do
     source temp_path
     notifies :run, "execute[restart svc]"
     only_if "test -f #{temp_path}"          # shell command, evaluated at converge
   end

   local_ruby_block "merge config" do
     block { ... }                            # Ruby code, evaluated at converge
     only_if { File.exist?(temp_path) }       # Proc, evaluated at converge
   end
   ```

`only_if` / `not_if` accept either a string (run as shell at converge time) or a Proc (run as Ruby at converge time). Both forms are lazy. Bare top-level Ruby is not.

**Detection** — when modifying or reviewing any cookbook recipe, search for the anti-pattern before declaring the change done:

```
git grep -nE '^if File\.exist\?|^unless File\.exist\?' cookbooks/
```

This rule exists because PRs #75 and #77 fixed the same `if File.exist?(temp_path)` bug across six cookbooks (codex-cli, mcp, ai-memory, cognee, hydra, notion), each requiring 2-3 mitamae passes to converge before the fix. The repo had already gained a related cluster of "Proc not_if" fixes (PRs #69-72) for the sibling problem of compile-time guards inside resource arguments — this rule names the umbrella class so the next contributor doesn't reinvent either form.

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
