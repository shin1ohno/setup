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

## Grep for in-codebase resource pattern before writing custom `execute`

Before writing an `execute` resource to perform a filesystem operation (`mkdir`, `chown`, `chmod`, `cp`, `install -d`, `install -m`, `ln -s`), grep the cookbook tree for an existing `directory` / `file` / `remote_file` resource that achieves the same effect. The DSL resource is preferable to a shell `execute` because it is idempotent by default, carries type checking, is visible to `mitamae --dry-run`, and survives audit greps for "what creates `/var/lib/foo`".

**Probe before writing custom shell**:

```bash
# Existing user-attribute precedents on directory resources
awk '/^[[:space:]]*directory /,/^end$/' cookbooks/*/default.rb | grep -B5 'user '

# Existing sudo-execute precedents (when DSL resource genuinely insufficient)
grep -rn 'sudo install\|sudo cp\|sudo mkdir' cookbooks/*/default.rb
```

**Resource attributes that solve common-execute cases**:

- Need to create a root-owned directory from a non-root mitamae context → `directory "/path" do; user "root"; owner "root"; group "root"; mode "0755"; end`. The base resource (`itamae/resource/base.rb:92`) defines `:user` on every resource; `run_specinfra` propagates it as `sudo -u <user>` to the underlying `mkdir`/`chown`. See `cookbooks/lazygit/default.rb:17-22` for precedent.
- Need to copy a file into a system path → `remote_file` for the staging copy + `execute "sudo install -m ..."` for the system move (the system-path part genuinely needs sudo — the DSL has no `user` shortcut equivalent for a `remote_file` writing into `/etc`, so split staging from install).

Custom `execute` is the fallback when the DSL resource cannot express the operation, NOT the reflex.

This rule exists because the 2026-05-07 node-exporter session reached for `execute "sudo install -d -m 0755 -o root -g root /var/lib/node_exporter"` mirroring the `lxc-pro-router` system-file pattern, when `cookbooks/lazygit/default.rb` already carried the simpler `directory ... user "root"` precedent that would have cost no `execute` at all. The user surfaced the cleaner approach with "directory の user 属性で実行ユーザーを指定できないですかね？" — a 10-second `awk` over the cookbook tree at design time would have found the precedent without the round-trip.

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

**Detection — run before declaring a cookbook review done**:

```
git grep -nE 'check_command:' cookbooks/ | grep -v -- '--profile'
```

Any hit is a false-gate candidate unless the cookbook genuinely uses the default AWS profile exclusively (rare — most service LXCs run with `pve-bootstrap-ssm` profile). This grep takes under one second and catches the class of bugs that caused silent SSM fetch failures in cognee (#143 fixed) and lxc-monitoring (#148 shipped with the bug, surfaced during 2026-05-06 apply when CT 111 had `pve-bootstrap-ssm` profile but no `default` profile → cookbook's bare `aws ssm get-parameter` check failed → non-TTY skip → Grafana stack silently undeployed). Fix: include `--profile <name>` in the `check_command`, sourcing the profile name from `cookbooks/ssh-keys/files/aws-config.json` (Phase A 2026-05-07 SSM 切替後; bootstrap config のみ in-repo、host registry 本体は SSM `/host-registry/devices`) like `auto-mitamae-target` does.

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

## sudo `secure_path` strips user home — symlink user-space tools into /usr/local/bin

`mitamae` execute resources with a `user` attribute run under `sudo -H -u <user> -- /bin/sh -c …`, which sanitizes PATH to sudoers' `secure_path` (typically `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`). Tools installed under the user's home — `~/.pyenv/shims/`, `~/.cargo/bin/`, `~/.local/bin/`, `~/.local/share/mise/shims/` — are NOT on `secure_path` and therefore invisible to that subshell. The user's own login shell finds them only because `.zshrc` / `.profile` prepended them; sudo bypasses that init.

This trap is invisible at recipe-write time: the cookbook's install resource succeeds, the verification probe via `which <tool>` (run in the user's shell) succeeds, and the failing consumer surfaces only when a sibling cookbook (or even the same cookbook) invokes the binary inside a sudo-wrapped execute.

**Fix**: symlink the binary into `/usr/local/bin/` so any PATH chain — sudo subshell, system-level service, cron — can resolve it:

```ruby
execute "symlink <tool> into /usr/local/bin" do
  command "ln -sf #{node[:setup][:home]}/.pyenv/shims/<tool> /usr/local/bin/<tool>"
  user node[:setup][:system_user]
  not_if "test -L /usr/local/bin/<tool> && " \
         "test \"$(readlink /usr/local/bin/<tool>)\" = " \
         "\"#{node[:setup][:home]}/.pyenv/shims/<tool>\""
end
```

Use the shim (not the resolved binary) so pyenv/mise version switches still take effect. The shim itself is a thin bash wrapper that finds the actual binary at exec time.

**When to apply this**: any cookbook installing a binary that will be invoked from a sudo-wrapped execute resource — including `git_clone` of a `codecommit::` URL (which spawns `git remote-codecommit` via its own subprocess), service unit files that call user-installed tools, cron jobs, etc.

**Detection**: when designing a cookbook that installs a Python/Rust/Node CLI tool, ask: "Will any privileged code path invoke this tool?" If yes, plan the symlink in the same cookbook.

This rule exists because the 2026-05-04 git-remote-codecommit cookbook installed the shim correctly via pyenv pip, but `git clone codecommit::…` failed inside `managed-projects' git_clone (sudo-wrapped) with `git: 'remote-codecommit' is not a git command`. Resolution required adding a `/usr/local/bin/git-remote-codecommit` symlink in the same cookbook.

## docker-compose service restart `execute` must guard on the config file existence

Cookbooks that drop a docker-compose service (hydra / cognee / ai-memory / hydra-server / etc.) typically have a `remote_file` for `.env` and a `docker compose up -d --build` execute that depends on it. The `.env` itself is usually generated by an SSM-gated execute that may legitimately skip on a fresh host without AWS credentials. When the gate is skipped, downstream notifies still fire the restart resource, which then attempts `docker compose up` without an `.env` and either fails the container at runtime (silent until logs are checked) or aborts the entire mitamae run.

**Fix**: gate the restart `execute` itself on `.env` existence, not just rely on the upstream gate:

```ruby
execute "docker compose restart hydra" do
  command "docker compose -f #{deploy_dir}/docker-compose.yml up -d --build"
  user node[:setup][:user]
  action :nothing
  only_if "test -f #{env_output_path}"
end
```

The guard is NOT an idempotency check — `not_if` would block re-runs after `.env` is in place. It is a fresh-machine safety check: skip the restart entirely on hosts that haven't completed the auth-gated bootstrap yet, with the expectation that the next mitamae run (after the operator configures auth) will pick up the restart on its own.

**Applies to**: any cookbook with both a) an SSM/secret-gated config file generation step, and b) a service restart that consumes that config file. The guard goes on the consumer, not the generator.

**Detection grep** — when modifying a docker-compose cookbook:

```
git grep -nE 'docker compose.*up' cookbooks/ | xargs -I{} grep -L only_if {}
```

Any restart resource without an `only_if "test -f <env>"` is a candidate, especially if it has `action :nothing` (notifies fire from upstream `remote_file` resources that don't themselves know about `.env` state).

This rule exists because the 2026-05-04 `linux.rb` LXC bootstrap session hit `hydra-migrate` failing to reach Aurora with empty credentials, traced back to the `docker compose restart hydra` execute firing despite the `.env` generator being skipped (no AWS auth on the LXC). Fixed by adding `.env`-existence guards to hydra / cognee / ai-memory / hydra-server restart resources in PR #103.

## Cookbook skip-paths must log at WARN, not INFO

When a cookbook exits early because a precondition is not met (hostname not in devices list, auth gate fails, SSM parameter absent, file not found), log at `MItamae.logger.warn(...)`, not `MItamae.logger.info(...)`. An `info`-level skip line is invisible at default log levels — the operator sees the cookbook "succeed" while observing zero effect, so the gap persists undetected until something downstream fails.

```ruby
# WRONG — silent skip, operator never notices
unless devices.key?(current_hostname)
  MItamae.logger.info("ssh-keys: #{current_hostname} not in devices.json, skipping")
  return
end

# RIGHT — visible skip; operator can grep "WARN" in the run log
unless devices.key?(current_hostname)
  MItamae.logger.warn(
    "ssh-keys: #{current_hostname} not in devices.json — no authorized_keys " \
    "written. Add this host to files/devices.json (or set its `hostname` " \
    "override field) if ssh-key distribution is intended."
  )
  return
end
```

Include the **consequence** in the warn message ("no authorized_keys written"), not just the guard condition. This makes the skip distinguishable from a benign no-op (e.g., "package already installed") at a glance.

The same WARN-vs-INFO discipline applies to any auth-gate fall-through, missing-config bypass, or `client_only`-style early return that an operator might want to know about. INFO is for "I did the thing successfully and here's a status note"; WARN is for "I did NOT do the thing and you might care."

This rule exists because setup PR #142 (2026-05-06) was required to fix `air`'s missing pubkeys. The root cause was a devices.json hostname mismatch, but the ssh-keys cookbook's `info`-level skip (`hostname '<serial>' not in devices.json, skipping`) was invisible in the apply output. The operator believed mitamae had succeeded and the bug persisted across multiple sessions until a per-device verification pass forced the hostname mismatch to surface.

## Rescue EPERM/EACCES on user-local override file reads

Cookbooks that read optional user-local override files (`*.local.json`, `*.local.md`, `*.local.rb`, user-supplied YAML) MUST rescue `Errno::EPERM` and `Errno::EACCES` and treat them as "file absent". On macOS, users frequently symlink these files into iCloud Drive (`~/Library/Mobile Documents/`). When mitamae runs without a desktop session (launchd timer, SSH from another host, remote apply), the macOS sandbox denies the symlink traversal with `EPERM` — even though the file is "there" from the user's perspective.

```ruby
# WRONG — hard crash when the symlink target is iCloud-sandboxed
local_overrides = JSON.parse(File.read("#{home}/.config/myapp/config.local.json"))

# RIGHT — graceful fallback; warn so the operator knows the override was skipped
local_overrides = begin
  if File.exist?("#{home}/.config/myapp/config.local.json")
    JSON.parse(File.read("#{home}/.config/myapp/config.local.json"))
  else
    {}
  end
rescue Errno::EPERM, Errno::EACCES => e
  MItamae.logger.warn(
    "myapp: cannot read local override (#{e.class}: #{e.message}) — " \
    "file may be a sandboxed iCloud symlink or have restrictive permissions; " \
    "using defaults."
  )
  {}
rescue JSON::ParserError => e
  MItamae.logger.warn("myapp: invalid JSON in local override (#{e.message}); using defaults.")
  {}
end
```

The same guard applies to any `File.read` that crosses a symlink the cookbook doesn't control — even `File.exist?` can raise `EPERM` on a sandboxed iCloud symlink in some macOS versions rather than returning `false`.

**Detection** — when adding any optional-override file read to a cookbook:

```
git grep -nE 'File\.read.*\.local\.|JSON\.parse.*\.local\.' cookbooks/ roles/
```

Any hit without a `rescue Errno::EPERM` (or wrapping `begin`/`rescue` block) is a candidate.

This rule exists because setup PR #147 (2026-05-06) was required after `roles/manage` on `air` raised `EPERM` on a `repositories.local.json` symlinked into iCloud Drive (`~/Library/Mobile Documents/.../securebu/repositories.local.json`). The unhandled exception halted the entire `darwin.rb` recipe chain — every cookbook downstream of `roles/manage` (managed-projects, mac-settings, edge-agent, macos-hub) silently never ran. The fix added `rescue Errno::EPERM, Errno::EACCES, JSON::ParserError` around the local-override read.

## remote_file idempotency guard — file-existence vs content-aware

`not_if "test -f #{path}"` on a `remote_file` resource guards against re-downloading on every run, but it does NOT detect when the cookbook source has changed since the file was first placed. During migrations (endpoint changes, address rotations, URL rewrites) the deployed file persists indefinitely with the old value — cookbook updates never propagate to existing hosts and the migration silently fails on the consumer side.

**Default for static configs**: `test -f` is fine. Use it when the cookbook's value for the file is not expected to change (e.g., a one-shot fetch of an upstream binary, a license file).

**When content drift matters** — config holds addresses, URLs, ports, or keys that the cookbook owns and may rewrite — switch to a content-aware guard:

```ruby
# grep-based: re-deploy whenever the expected new value is absent
remote_file config_path do
  source "files/config.toml"
  not_if "grep -qF '#{expected_value}' #{config_path} 2>/dev/null"
end
```

**Migration-specific pattern**: when a cookbook is mid-migration from an old value to a new one, write the guard against the *old* value with negation. This re-deploys exactly the hosts still pinned to the old value, leaves migrated hosts untouched, and self-heals across the fleet without flag days:

```ruby
remote_file config_path do
  source "files/config-#{variant}.toml"
  # Skip when the file exists AND no longer references the old endpoint.
  # Hosts still pinned to the old value get re-deployed on next mitamae apply.
  not_if "test -f #{config_path} && " \
         "! grep -q 'OLD_ENDPOINT' #{config_path}"
end
```

After all hosts have migrated, simplify the guard back to `test -f` in a follow-up commit. Leaving the migration-specific grep permanently is harmless but adds noise for the next maintainer.

This rule exists because setup PR #130 (2026-05-05) migrated edge-agent's `config_server_url` from `192.168.1.20:3101` (pre-PVE weave-server on pro) to `weave.home.local:8888` (PVE CT 109). The cookbook had `not_if "test -f #{config}"`, which would have left neo / air pinned to the dead endpoint forever despite the cookbook source being correct. The migration-specific grep guard solved this without changing semantics for new-host installs.

## SSM-sourced `.env` generator: file-existence skip_if drops new KEY=VALUE lines silently

When a cookbook uses `require_external_auth(skip_if: -> { File.exist?(env_output_path) })` (or `not_if "test -f #{env_path}"` on the `execute "generate ... .env"` resource) to avoid re-fetching from SSM on every apply, ADDING a new key to the underlying `generate_env.sh` script does NOT take effect on existing hosts. The skip_if returns true (`.env` already exists), the generate execute is skipped, no new content is produced, and the running container's `env_file` continues to load the OLD `.env` that lacks the new key. Cookbook apply reports success; the container's env is silently incomplete.

The trap is invisible at code-review time (the generator change is correct) and at dry-run time (no resource fails). It surfaces only at functional verification — `docker exec <container> env | grep NEW_KEY` is empty even after a green apply.

**Default for static credentials**: file-existence skip_if is fine when the generator's output shape is stable (e.g., `.env` holds only `LLM_API_KEY` + `DB_PASSWORD` and that set never grows). Saves redundant SSM round-trips on re-apply.

**When generator content drifts** — adding a new SSM-sourced key, restructuring lines — use a content-aware guard that checks for the expected new key:

```ruby
require_external_auth(
  tool_name: "AWS CLI for /<service>/* SSM params",
  check_command: "aws ssm get-parameter --name /<service>/<probe-key> ...",
  # Skip only when .env exists AND already contains every key generate_env.sh
  # writes. Adding a new line to the generator → File.read mismatch →
  # block fires → fresh fetch.
  skip_if: -> {
    File.exist?(env_output_path) &&
      File.read(env_output_path).include?("OTEL_EXPORTER_OTLP_HEADERS=") &&
      File.read(env_output_path).include?("APM_API_KEY=")
  },
) do
  execute "generate <service> .env" do
    command "AWS_PROFILE=... bash #{generate_env_script} #{env_temp_path}"
  end
end
```

For the simple case (one canonical key per generator change), single-key check is enough. For multi-key generators, list every key the generator writes — adding a key to the list when adding to the script is the discipline that keeps drift detection accurate.

**Alternative — drop skip_if + let mitamae's `remote_file` diff handle no-ops**: regenerate `.env` to a temp path on every apply, then `remote_file env_output_path source env_temp_path`. mitamae's remote_file already content-diffs — same `.env` → no notify, no restart. Cost: every apply pays the SSM round-trip (1-5s per key); benefit: zero drift class.

**Detection grep** for reviewing other cookbooks:

```bash
git grep -B2 -A1 'skip_if.*File.exist' cookbooks/ | grep -B2 'env_output_path\|\.env'
```

Any hit that doesn't check additional content beyond file existence is a candidate, especially if the cookbook's `generate_env.sh` fetches more than one SSM key.

**Recovery procedure** on affected hosts (existing `.env` predates the new key):

```bash
# Per affected host (CT 105 / 107 in the originating incident).
pct exec <ct> -- bash -c 'mv /root/deploy/<service>/.env /root/deploy/<service>/.env.bak-pre-<feature>-$(date +%F)'
pct exec <ct> -- bash -lc 'cd /root/setup && ./bin/mitamae local pve/lxc-<service>.rb'
# Verify: docker exec <container> env | grep <NEW_KEY> must show the value.
```

This rule exists because the 2026-05-12 APM Phase 5 rollout's cookbook PRs (setup #337 cognee, #333 ai-memory) added `OTEL_EXPORTER_OTLP_HEADERS=...` to `generate_env.sh` for both services, but `require_external_auth(skip_if: -> { File.exist?(env_output_path) })` made the generator a no-op on hosts whose `.env` predated the change. The container env had OTEL_SERVICE_NAME / ENDPOINT / CERTIFICATE (from docker-compose `environment:` block) but NOT OTEL_EXPORTER_OTLP_HEADERS (the one from env_file), so OTLP exports went out without auth → apm-server rejected them silently → service.name absent from `traces-apm-default`. Recovery required manual `.env` rename + reapply on every affected host. The content-aware skip_if would have re-fetched on the first apply post-merge.

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

This rule exists because setup PR #131 (2026-05-05) introduced `owner 1000` (Integer) for `/var/lib/roon-mcp/state/` resources. CI passed. The mitamae apply on CT 108 immediately failed with `InvalidTypeError`, requiring hotfix PR #133. One full PR + CI cycle wasted on a class of bug no static check catches. The grep above run before commit would have caught it.

## Defensive `directory` resource for `node[:setup][:root]` and its subdirs

Any cookbook that places files (`remote_file`, `file`) under `node[:setup][:root]` (typically `~/.setup_shin1ohno`) MUST declare a `directory` resource for the parent path BEFORE the first write — even though most existing LXCs already have the directory from a prior cookbook run.

```ruby
directory node[:setup][:root] do
  mode "755"
end

directory "#{node[:setup][:root]}/<cookbook-name>" do
  mode "755"
end

remote_file "#{node[:setup][:root]}/<cookbook-name>/<artifact>" do
  source "files/<artifact>"
  mode "755"
end
```

Why both the parent and a per-cookbook subdirectory:
- **Parent**: the `node[:setup][:root]` directory is *conventionally* expected to exist, but no single cookbook owns its creation. It happens to exist on dev boxes from prior mitamae runs; on a freshly-bootstrapped LXC (`apt install git curl && git clone && ./bin/setup && ./bin/mitamae local pve/lxc-<name>.rb`) the first cookbook to write under it sees a missing parent and fails with `cp: cannot create regular file '...': No such file or directory`.
- **Per-cookbook subdir**: matches the `cookbooks/awscli` and `cookbooks/eternal-terminal` convention and keeps each cookbook's staged artifacts in their own namespace, simplifying cleanup and audit.

The dry-run gate does NOT catch this — `mitamae local --dry-run` on the dev box reports the file resource as "exist will change from false to true" because it only previews, and the directory existence on the dev box hides the runtime mkdir need.

Detection: `git grep -nE 'node\[:setup\]\[:root\]' cookbooks/ | grep -v 'directory '` — any hit not associated with a `directory` resource is a candidate.

This rule exists because setup PR #137 (2026-05-05) shipped `auto-mitamae` placing `auto-mitamae.sh` under `node[:setup][:root]` without a defensive `directory` resource. Dry-run on the dev box passed. CT 109 bootstrap failed at converge with `cp: cannot create regular file '/root/.setup_shin1ohno/auto-mitamae.sh'`. Hotfix PR #138 added the two `directory` resources and re-namespaced into `<setup_root>/auto-mitamae/`.

## When automating mitamae, enumerate the privilege boundary at plan time

Any cookbook that schedules `mitamae local <role>.rb` (systemd timer, cron, launchd LaunchAgent, CI runner) MUST answer this question in the plan BEFORE writing the timer unit:

> Does the target role include resources that need root? Check for: `sudo` in `execute` commands, system package installs (`apt install`, `brew --root` paths), service restarts that touch `/etc/systemd/system/`, file resources writing under `/etc/`, `/usr/`, `/var/lib/`, or any path outside the user's home.

The answer determines the timer's privilege model:

| Need root? | Timer model |
|---|---|
| Yes (cookbook touches /etc, /usr, services) | systemd **system** timer (`/etc/systemd/system/`, `User=root`) — bootstrap requires 1-time `sudo mitamae`, all subsequent fires run as root |
| No (user-space only: dotfiles, mise, ~/.config/*) | systemd **user** timer (`~/.config/systemd/user/`, `loginctl enable-linger <user>`) — never needs sudo |
| Mixed | Split the role into a user-mode subset (`roles/auto-mitamae-userspace.rb`) for the timer + keep the full role for manual `sudo mitamae` |

If you put a root-needing role behind a user-mode timer, mitamae **silently skips or partially fails** root resources (`Permission denied`) without raising — drift accumulates invisibly until something breaks.

If your design enumerates "I need to run mitamae automatically" without spelling out which of the three rows above applies, the design is incomplete. Treat this as a plan-completeness check, equivalent to listing affected files.

This rule exists because the auto-mitamae plan (PR #137, 2026-05-05) initially proposed a user-mode systemd timer modeled on `cookbooks/s3-backup`'s pattern, without auditing whether the target role had root resources. The user surfaced the gap mid-plan-review with "mitamae 実行に sudo が必要ですが、どうしますか？", costing one full plan-revision cycle. The fix landed as a 4-row decision in the plan; the rule above prevents the next planner from missing it.

## Docker Build in Unprivileged PVE LXC

`docker build` / `docker compose up --build` inside an unprivileged PVE LXC requires **two** prerequisites to be true simultaneously:

1. `features_nesting=true` on the LXC config (Terraform: `features_nesting = true`). Without it the containerd overlayfs snapshotter cannot rbind-mount image layers and aborts during pull / extract with `permission denied` / `failed to mount /var/lib/containerd/tmpmounts/...`. This is a PVE-side change — `pct set <vmid> --features nesting=1` or via the bpg/proxmox provider — and requires LXC restart.

2. `DOCKER_BUILDKIT=0` prefix on every `docker compose up --build` and `docker build` invocation. BuildKit's mount namespacing fails inside the container even with nesting enabled (`failed to mount … rbind ro: permission denied` in the buildkit-mount step). The classic builder is happy with the same setup. Cookbook pattern:

```ruby
execute "ensure <stack> running" do
  command "DOCKER_BUILDKIT=0 docker compose -f #{compose_path} up -d --build"
  user user
end
```

**Caveat — git context with subdirectory**: BuildKit supports `https://repo.git#ref:subdir` to make build context a subdirectory of the repo. Classic builder does NOT support that syntax. If your Dockerfile MUST be built from a subdir (e.g., a Next.js app whose `Dockerfile` does `COPY package.json` expecting `package.json` at root), you cannot use classic builder. Workarounds: (a) bind-mount a pre-cloned tree as the context, (b) move the Dockerfile to expect a wider context, or (c) put the build on a Docker host that isn't unprivileged (e.g., on the PVE host directly).

This rule exists because PRs #115 → #119 in setup spent 5 PR cycles iterating through this combination during the 2026-05-04 PVE-migration session. The discovery sequence was: nesting=false → containerd rbind fail; nesting=true alone → buildkit rbind fail; nesting=true + BUILDKIT=0 → success for repo-root Dockerfiles; the weave-web subdir case forced one Dockerfile back onto BuildKit (classic doesn't support subdir context) which then needed nesting alone. Documenting the matrix prevents the next mitamae-on-PVE-LXC author from rediscovering each step.

## Debian 13 Minimal LXC — Mandatory Bootstrap Packages

PVE Debian 13 (`bookworm` / `trixie`) **unprivileged LXC templates ship without** `gnupg`, `unzip`, and `ca-certificates`, and the apt index is not populated until first `apt-get update`. Cookbooks targeting fresh LXCs that omit any of these will fail in non-obvious ways:

- `gnupg` missing → `gpg --dearmor` step in any apt-key import (Docker, NodeSource, Postgres) errors with `gpg: command not found`. Recovery requires apt-installing gnupg, but the install needs apt index, and the index needs the repo, and the repo needs the key…
- `unzip` missing → installer scripts that fetch a zipped release (rclone `install.sh`, awscli `awscliv2.zip`) abort with cryptic "no extractor found" errors
- Stale apt index → `apt-get install <pkg>` succeeds for things in the base image's dpkg cache and silently misses anything published after image build

**Required first resource** in any cookbook targeting Debian 13 unprivileged LXCs:

```ruby
execute "install bootstrap deps" do
  command "apt-get update -qq && apt-get install -y gnupg unzip ca-certificates curl"
  not_if "dpkg -s gnupg unzip ca-certificates curl >/dev/null 2>&1"
end
```

Run before any apt repo addition, any zip extraction, or any package install that came in via custom apt sources.

This rule exists because PRs #108-#110 in setup were three sequential apply cycles to fix the same class of bug — each cookbook (docker-engine, rclone, awscli) was missing the bootstrap-deps guard and failing on a different downstream step of the same root cause. A single cookbook-side check at the beginning of the PVE-LXC entry recipes would have collapsed all three PRs into zero.

## IP literal must come from contracts/devices.json (plan-phase probe)

Before writing any IP literal into a cookbook (`execute` command, `template` substitution, Prometheus scrape target, `discovery.seed_hosts`, healthcheck URL), probe the source of truth and confirm the match:

```bash
jq -r '.devices | to_entries[] | select(.value.kind=="lxc") | "\(.key) ip=\(.value.lxc.ip // "?") ct_id=\(.value.lxc.ct_id // "?")"' \
  ~/ManagedProjects/home-monitor/contracts/devices.json
```

This catches the **CT-ID-shaped IP confusion**: hardcoded `192.168.1.{112,113,114}` matches CT IDs visually but the real LXC IPs are `.77/.78/.79`. The two are visually similar but only the real values route — ARP `ip neigh show` reports `INCOMPLETE` for the wrong ones, ES discovery throws `connect_exception: No route to host` from Java/Netty, and `pct exec` ICMP ping confusingly succeeds (kernel kept the L2 path) so the bug looks like an ES configuration issue.

Hardcoded IPs are a **plan-completeness failure**, not a post-apply diagnosis. The probe is a 2-second plan-phase step.

This rule exists because the 2026-05-09 ADR-0005 Phase 3b session lost ~3 hours debugging cluster discovery failures rooted in two cookbook files (`elasticsearch.yml.tmpl` seed_hosts + `pve/lxc-es-{0,1,2}.rb` `transport_host`) hardcoding CT-ID-shaped IPs. PRs #247 and #248 fixed both. `contracts/devices.json` had the correct `.77/.78/.79` values the entire session — never consulted at plan time.

## Cookbook converge fail — diagnose all remaining resources before first fix PR

When `mitamae apply` (or `docker compose up + bootstrap script`) fails on a target host, **DO NOT** open a fix PR for the first error. Instead:

1. Let the apply complete (or kill it cleanly)
2. Probe the full state:
   ```
   ssh root@<vmid> 'systemctl --failed; docker ps -a; docker logs <container> --tail 80 2>&1 | grep -iE "ERROR|FATAL|denied"; ls -la /data/<service>/ 2>&1'
   ```
3. Collect every fail signal (resource state mismatches, container exit codes, log error patterns, file permission issues)
4. Open one fix PR addressing all of them

Why batched: each fix-PR-CI-merge-redeploy cycle takes 5-10 min. Sequential fix PRs for diagnosable-in-one-pass bugs multiply waste.

**Exception**: bug B is genuinely unobservable until bug A is fixed (e.g., container won't start until cert ownership fixed → can't probe ES auth until container running). Batching the related-bug-cluster is correct, but the dependency must be genuine — not "I noticed A first so let me ship A".

This rule exists because the 2026-05-09 ADR-0005 Phase 3b session shipped 6 sequential fix PRs (#242 → #243 → #244 → #245 → #247 → #248), ~30-60 min of avoidable cycle time. Bugs #5/#6 (the IP confusion above) were diagnosable from the first ES log line "No route to host" via `pct exec <vmid> -- ip neigh show` (would have shown `INCOMPLETE` immediately). Bugs #7/#8 (cert ownership + healthcheck quoting) surfaced later but were independent and could have been in the same batch as the network bugs.

