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

