---
globs: "*.rb"
---

# Ruby Code Guidelines

- When working with mitamae DSL: use `not_if` / `only_if` for idempotency checks
- Prefer symbols over strings for hash keys in DSL code
- mitamae runs without sudo. Never use `owner node[:setup][:system_user]` on file/remote_file resources — it triggers an internal `sudo chown` that fails without a terminal. Instead, stage files in user space (`node[:setup][:root]`) and use `execute` with explicit `sudo cp` to place them in system directories

This file is the always-loaded summary. Long examples + origin notes are in `~/.claude/docs/ruby-detail.md` (NOT auto-imported — load on demand via Read tool when a section pointer matches the current task).

## Grep for in-codebase resource pattern before writing custom `execute`

Detail: see `~/.claude/docs/ruby-detail.md#grep-existing-resource`.

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

Origin: 2026-05 — `if File.exist?(temp_path)` compile-time bug across six cookbooks needing 2-3 converge passes.

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

Origin: 2026-04-25 neo bootstrap — ssh-keys gated on bare `aws sts get-caller-identity` but invoked SSM with `--profile sh1admn`; neo had only `default` → gate passed → silent fetch_ssm cascade.

**Detection — run before declaring a cookbook review done**:

```
git grep -nE 'check_command:' cookbooks/ | grep -v -- '--profile'
```

Any hit is a false-gate candidate unless the cookbook genuinely uses the default AWS profile exclusively (rare — most service LXCs run with `pve-bootstrap-ssm` profile). Fix: include `--profile <name>` in the `check_command`, sourcing the profile name from `cookbooks/ssh-keys/files/aws-config.json` (host registry 本体は SSM `/host-registry/devices`) like `auto-mitamae-target` does. Origin: 2026-05-06 lxc-monitoring — bare gate passed on CT 111 (had `pve-bootstrap-ssm`, no `default`) → Grafana silently undeployed.

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

Origin: 2026-04-25 — `require_external_auth` helper hung 3 CI runs 1+ hr each (non-TTY `gets` returned nil); local TTY hid it.

## sudo `secure_path` strips user home — symlink user-space tools into /usr/local/bin

Detail: see `~/.claude/docs/ruby-detail.md#secure-path-symlink`.

## docker-compose service restart `execute` must guard on the config file existence

Detail: see `~/.claude/docs/ruby-detail.md#dc-restart-only-if-guard`.

## Cookbook skip-paths must log at WARN, not INFO

Detail: see `~/.claude/docs/ruby-detail.md#warn-vs-info-skip`.

## Rescue EPERM/EACCES on user-local override file reads

Detail: see `~/.claude/docs/ruby-detail.md#rescue-eperm-icloud`.

## remote_file idempotency guard — file-existence vs content-aware

Detail: see `~/.claude/docs/ruby-detail.md#remote-file-content-aware-guard`.

## SSM-sourced `.env` generator: file-existence skip_if drops new KEY=VALUE lines silently

Detail: see `~/.claude/docs/ruby-detail.md#ssm-env-skip-if-drift`.

## mitamae directory/file `owner`/`group` MUST be String, not Integer

mitamae's `directory` and `file` resources accept `owner` / `group` as a **String** only — Integer literals raise `MItamae::Resource::InvalidTypeError: owner attribute should be String` at converge time. The error fires per-resource at apply on the target host, NOT at compile or `mitamae --dry-run` time, so the typo survives `ruby -c`, CI's syntax-check job, and even the cookbook's own dry-run gate.

**Wrong** (silently passes CI, fails on first apply):

```ruby
directory "/var/lib/myservice/state" do
  owner 1000
  group 1000
  mode "755"
end
```

**Right** (use string form even for numeric UIDs):

```ruby
directory "/var/lib/myservice/state" do
  owner "1000"
  group "1000"
  mode "755"
end
```

The String requirement is the same whether the value is a username (`"shin1ohno"`) or a numeric UID stringified (`"1000"`). The latter is the only safe form when the cookbook needs an explicit UID that does not match a `useradd`-created system user — typical for container-mounted state directories where the `owner` must match a docker compose `user: "${UID}:${GID}"` directive.

**Detection** — when reviewing or writing a cookbook with bare numeric `owner`/`group`:

```
git grep -nE 'owner\s+[0-9]+|group\s+[0-9]+' cookbooks/
```

A non-empty result is a bug. Quote each match.

Origin: 2026-05-05 — `owner 1000` (Integer) for `/var/lib/roon-mcp/state/`; CI passed, mitamae apply on CT 108 failed with `InvalidTypeError`.

## Defensive `directory` resource for `node[:setup][:root]` and its subdirs

Detail: see `~/.claude/docs/ruby-detail.md#setup-root-directory`.

## When automating mitamae, enumerate the privilege boundary at plan time

Detail: see `~/.claude/docs/ruby-detail.md#automate-mitamae-privilege`.

## Docker Build in Unprivileged PVE LXC

Detail: see `~/.claude/docs/ruby-detail.md#docker-build-unprivileged-lxc`.

## Debian 13 Minimal LXC — Mandatory Bootstrap Packages

Detail: see `~/.claude/docs/ruby-detail.md#debian13-bootstrap-deps`.

## IP literal must come from contracts/devices.json (plan-phase probe)

Before writing any IP literal into a cookbook (`execute` command, `template` substitution, Prometheus scrape target, `discovery.seed_hosts`, healthcheck URL), probe the source of truth and confirm the match:

```bash
jq -r '.devices | to_entries[] | select(.value.kind=="lxc") | "\(.key) ip=\(.value.lxc.ip // "?") ct_id=\(.value.lxc.ct_id // "?")"' \
  ~/ManagedProjects/home-monitor/contracts/devices.json
```

This catches the **CT-ID-shaped IP confusion**: hardcoded `192.168.1.{112,113,114}` matches CT IDs visually but the real LXC IPs are `.77/.78/.79`. The two are visually similar but only the real values route — ARP `ip neigh show` reports `INCOMPLETE` for the wrong ones, ES discovery throws `connect_exception: No route to host` from Java/Netty, and `pct exec` ICMP ping confusingly succeeds (kernel kept the L2 path) so the bug looks like an ES configuration issue.

Hardcoded IPs are a **plan-completeness failure**, not a post-apply diagnosis. The probe is a 2-second plan-phase step.

Origin: 2026-05-09 ADR-0005 Phase 3b — ~3 hrs debugging ES discovery failures from two cookbook files (`elasticsearch.yml.tmpl` seed_hosts + `pve/lxc-es-{0,1,2}.rb` `transport_host`) hardcoding CT-ID-shaped IPs; `contracts/devices.json` had the correct `.77/.78/.79` all along.

## Cookbook converge fail — diagnose all remaining resources before first fix PR

Detail: see `~/.claude/docs/ruby-detail.md#converge-fail-batch-diagnose`.

## `mitamae --dry-run` requires `dangerouslyDisableSandbox`

`mitamae local <role>.rb --dry-run` (and any wrapper, e.g. `./bin/apply --dry-run`) fails inside the Claude Code command sandbox with `touch: /tmp/<rand>: Operation not permitted` → `Command 'touch /tmp/<rand>' failed`. mitamae's `remote_file` resource probes writability with a `touch /tmp/<rand>` during the converge/dry-run pass, and the command sandbox only permits writes under `/tmp/claude` + `$TMPDIR`. The error aborts on the FIRST `remote_file` resource — often an unrelated cookbook (e.g. git config) — before reaching the cookbook you are validating, so it reads like a cookbook bug rather than a sandbox limit.

Run mitamae dry-runs with `dangerouslyDisableSandbox: true`. This is distinct from the general "retry sandbox-disabled on a network error" rule: it fires on EVERY dry-run regardless of cookbook content or network use, purely from the `/tmp` touch probe.

Origin: 2026-06-28 zp-issue-loops — `./bin/apply --overlay-only --dry-run` blocked on `touch /tmp/...: Operation not permitted` at the git cookbook until the sandbox was disabled.

## mruby API constraints — File.mtime / File.stat not available

mitamae runs on **mruby**, not CRuby. The `File` class in mruby is a strict subset:

- **Available**: `File.exist?`, `File.read`, `File.join`, `File.dirname`, `File.basename`, `File.expand_path`
- **NOT available**: `File.mtime`, `File.stat`, `File.size`, `File.birthtime`, any `File::Stat` methods

CI syntax-check jobs run CRuby (`ruby -c`), which has all of these. A cookbook using `File.mtime` or `File.stat` inside a `skip_if` / `not_if` Proc passes CI, passes `ruby -c`, and aborts at converge time on every real target with `undefined method 'mtime' (NoMethodError)`.

**Rule**: any time/age/size logic in a `skip_if` / `not_if` / `only_if` guard MUST be expressed as a shell command (string form), not a Ruby Proc:

```ruby
# WRONG — File.mtime is CRuby only; NoMethodError on mruby
skip_if: -> { File.exist?(sentinel) && (Time.now - File.mtime(sentinel)) < 86400 }

# RIGHT — delegate time/age logic to bash
skip_if: "test -f #{sentinel} && find #{sentinel} -mmin -1440 | grep -q ."
```

**Trigger**: any `not_if` / `only_if` / `skip_if` that references `File.mtime`, `File.stat`, `File.size`, or any `File::Stat` method.

**Detection**:

```bash
git grep -nE 'File\.(mtime|stat|size|birthtime|ctime|atime)' cookbooks/
```

Any hit inside a Proc is a mruby NoMethodError waiting to fire.

**Why CI cannot catch this**: the syntax-check job uses the system Ruby (CRuby). Only running `mitamae local <role>.rb` under the real mruby binary (or `mitamae --dry-run`) on a target host exposes the missing method. `mitamae --dry-run` on the dev box also uses mruby, so a dry-run on any LXC is a faster feedback loop than waiting for a production apply failure.

Origin: 2026-06-10 KMS-reduction ES snapshot cookbook — `skip_if: -> { ... File.mtime(sentinel) ... }` passed CI (CRuby), every ES-node apply aborted `NoMethodError: undefined method 'mtime'` (mruby). The mruby runtime is the only gate that counts.
