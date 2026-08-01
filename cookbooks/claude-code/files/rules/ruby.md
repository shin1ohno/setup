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

mitamae loads every recipe as Ruby (compile phase) before running any resource (converge phase). All top-level Ruby control flow (`if`, `unless`, `case`, plain method calls) executes at compile time, so any state check that depends on a side effect of a preceding `execute` / `remote_file` / `file` resource sees the **pre-converge** state — the guarded resources are never added to the collection on a clean run (the "needs 2-3 passes to converge" symptom). Two correct patterns: (1) a single-pipeline `execute` doing generate + install + cleanup in one shell command, or (2) resource-level `only_if` / `not_if` (string = shell at converge, Proc = Ruby at converge) — both are lazy; bare top-level Ruby is not.

**Detection** — when modifying or reviewing any cookbook recipe, search for the anti-pattern before declaring the change done:

```
git grep -nE '^if File\.exist\?|^unless File\.exist\?' cookbooks/
```

Detail: see `~/.claude/docs/ruby-detail.md#mitamae-compile-time`.

## Auth-check gate must match the cookbook's actual invocation profile

When writing a `require_external_auth` (or any auth-check gate) in a cookbook, the `check_command` MUST use the exact same `--profile` and `--region` (and any other identity-affecting flags) as the cookbook's actual operations. A gate that passes against a different identity is a false gate — it lets the cookbook proceed and then silently fail at the real call. Stronger: make the `check_command` attempt the actual resource read the cookbook will need (the real `aws ssm get-parameter --name ... --profile ...`), not a bare `aws sts get-caller-identity`.

**Validation question**: "if the named profile is absent, does my gate fail?" If the answer is "depends on whether default profile is present", the gate is wrong.

**Detection — run before declaring a cookbook review done**:

```
git grep -nE 'check_command:' cookbooks/ | grep -v -- '--profile'
```

Any hit is a false-gate candidate unless the cookbook genuinely uses the default AWS profile exclusively (rare — most service LXCs run with `pve-bootstrap-ssm` profile). Fix: include `--profile <name>` in the `check_command`, sourcing the profile name from `cookbooks/ssh-keys/files/aws-config.json` (host registry 本体は SSM `/host-registry/devices`) like `auto-mitamae-target` does.

Detail: see `~/.claude/docs/ruby-detail.md#auth-check-gate-profile`.

## Capability guards must attempt the operation, not check for its prerequisite

A guard that tests whether a credential/key/tool is PRESENT can pass on a host where the operation still fails — and enabling the operation there is often worse than leaving it off, because the failure only appears once the prerequisite arrives. Gate on the smallest real attempt instead, in the same invocation shape the consumer uses. Concretely: `gpg --list-secret-keys <id>` succeeds for a passphrase-protected or stub key that cannot sign unattended, so gate `commit.gpgsign` on `printf x | gpg --batch --yes -bsau <id> -o /dev/null` (git's own `sign_buffer` shape) instead.

Detail: see `~/.claude/docs/ruby-detail.md#capability-guard-not-presence`.

## Never build a shell command with Ruby's `%` / `format`

`%`/`format`/`sprintf` parses EVERY `%` in the template as a format specifier, so a shell fragment carrying its own `printf "%s"`, a `%20` in a URL, or a strftime token collides with it — raising `ArgumentError: named<known> after unnumbered(1)` when the styles mix, or substituting silently wrong values when the counts happen to align. Use a heredoc with `#{}` interpolation, which only touches what you mark.

Detail: see `~/.claude/docs/ruby-detail.md#string-percent-shell-collision`.

## STDIN.tty? guard before any blocking STDIN read

Any Ruby cookbook helper (or any mitamae recipe code) that reads from STDIN MUST check `STDIN.tty?` before entering a blocking read or loop. In non-TTY contexts (CI, agent-driven runs, dry-runs over ssh without `-t`), `STDIN.gets` returns `nil` immediately — and `nil` is not a useful loop-exit signal. Fail-soft (log WARN + `yield`/`return`) in the non-TTY branch. Never rely on `gets` returning nil as a loop-exit signal.

Detail: see `~/.claude/docs/ruby-detail.md#stdin-tty-guard`.

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

## Guard must be evaluatable under mitamae's actual runtime privilege

A `not_if` / `only_if` / `skip_if` guard MUST succeed under the privilege mitamae actually runs with (typically a **non-root operator user** — `mitamae runs without sudo`, see the top of this file). A guard that reads a **root-owned file** (`/etc/sudoers.d/*` = `0440 root:wheel`, `0600` credentials, `/etc/ssl/private/*`) via `diff -q` / `cmp` / `grep -q` hits a read error as non-root → non-zero exit → the guard evaluates false. The failure mode depends on the guard type, and both are silent:

- **`not_if`**: always false → the resource re-runs on **every apply** (`visudo` + `sudo install` fire each time — silent non-idempotency; the apply still reports success)
- **`only_if`**: always false → the resource is **permanently, silently skipped** (worse — the config that should be placed is never updated)

`2>/dev/null` only hides the read error; it does NOT change the exit code. The **file's own mode** decides readability, not the parent dir's ("sudoers.d is 0755 so the diff needs no sudo" is the exact misconception that ships this bug). Preferred fix: a privilege-free hash sentinel written to user space in the same placement `execute` (works on non-TTY fleet hosts); `sudo diff -q` works only on interactive darwin applies with a warm sudo timestamp.

**Probe before writing the guard** — as the operator user, not just `ls -la` (which misses group membership):

```bash
test -r <path> && echo READABLE || echo NOT_READABLE
```

**Detection grep** (cookbook review / `lint-cookbooks` candidate check):

```bash
git grep -nE '(not_if|only_if).*(diff -q|cmp |grep -q).*(/etc/sudoers|/etc/ssl/private|\.d/)' cookbooks/
```

Any hit — check the placement mode (the `install -m` argument). If it is `0440` / `0400` / `0600`, this rule applies.

Detail: see `~/.claude/docs/ruby-detail.md#guard-runtime-privilege`.

## SSM-sourced `.env` generator: file-existence skip_if drops new KEY=VALUE lines silently

Detail: see `~/.claude/docs/ruby-detail.md#ssm-env-skip-if-drift`.

## mitamae directory/file `owner`/`group` MUST be String, not Integer

mitamae's `directory` and `file` resources accept `owner` / `group` as a **String** only — Integer literals raise `MItamae::Resource::InvalidTypeError: owner attribute should be String` at converge time. The error fires per-resource at apply on the target host, NOT at compile or `mitamae --dry-run` time, so the typo survives `ruby -c`, CI's syntax-check job, and even the cookbook's own dry-run gate. Use the string form even for numeric UIDs (`owner "1000"`) — the only safe form when the UID must match a docker compose `user: "${UID}:${GID}"` directive rather than a `useradd`-created user.

**Detection** — when reviewing or writing a cookbook with bare numeric `owner`/`group`:

```
git grep -nE 'owner\s+[0-9]+|group\s+[0-9]+' cookbooks/
```

A non-empty result is a bug. Quote each match.

Detail: see `~/.claude/docs/ruby-detail.md#owner-group-string`.

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

This catches the **CT-ID-shaped IP confusion** (hardcoded `192.168.1.{112,113,114}` visually match CT IDs but the real LXC IPs are `.77/.78/.79`). Hardcoded IPs are a **plan-completeness failure**, not a post-apply diagnosis. The probe is a 2-second plan-phase step.

Detail: see `~/.claude/docs/ruby-detail.md#ip-literal-devices-json`.

## Cookbook converge fail — diagnose all remaining resources before first fix PR

Detail: see `~/.claude/docs/ruby-detail.md#converge-fail-batch-diagnose`.

## `mitamae --dry-run` requires `dangerouslyDisableSandbox`

`mitamae local <role>.rb --dry-run` (and any wrapper, e.g. `./bin/apply --dry-run`) fails inside the Claude Code command sandbox on a `touch /tmp/<rand>` writability probe (`Operation not permitted`) that mitamae's `remote_file` resource runs during the converge/dry-run pass. Run mitamae dry-runs with `dangerouslyDisableSandbox: true`. This fires on EVERY dry-run regardless of cookbook content or network use — distinct from the general "retry sandbox-disabled on a network error" rule.

Detail: see `~/.claude/docs/ruby-detail.md#dry-run-sandbox`.

## mruby API constraints — File.mtime / File.stat / Integer#zero? not available

mitamae runs on **mruby**, not CRuby, and mruby simply lacks a number of CRuby convenience methods. `ruby -c` (CRuby) accepts every one of them, so the gap only surfaces at converge time. The `File` class is a strict subset:

- **Available**: `File.exist?`, `File.read`, `File.join`, `File.dirname`, `File.basename`, `File.expand_path`
- **NOT available**: `File.mtime`, `File.stat`, `File.size`, `File.birthtime`, any `File::Stat` methods

Beyond `File`, other core-class predicates are missing too — **`Integer#zero?` is confirmed absent**; write `== 0`, which is also this codebase's existing idiom (`cookbooks/git/default.rb`'s `dpkg-query` guard). Treat any CRuby convenience predicate as unconfirmed until it has run under the real mruby binary once.

CI syntax-check jobs run CRuby (`ruby -c`), which has all of these. A cookbook using `File.mtime`, `File.stat`, or `Integer#zero?` passes CI, passes `ruby -c`, and aborts at converge time on every real target with `undefined method '…' (NoMethodError)`. **CI's own `test-linux` / `test-macos` dry-run jobs DO catch it** — they run the real mruby binary — so a red dry-run job on a green `syntax-check` is the signature of this class.

**Rule**: any time/age/size logic in a `skip_if` / `not_if` / `only_if` guard MUST be expressed as a shell command (string form), not a Ruby Proc:

```ruby
# WRONG — File.mtime is CRuby only; NoMethodError on mruby
skip_if: -> { File.exist?(sentinel) && (Time.now - File.mtime(sentinel)) < 86400 }

# RIGHT — delegate time/age logic to bash
skip_if: "test -f #{sentinel} && find #{sentinel} -mmin -1440 | grep -q ."
```

The same substitution applies to `Integer#zero?` — use `== 0` anywhere the value flows through mruby-executed code, guard or not.

**Trigger**: any `not_if` / `only_if` / `skip_if` that references `File.mtime`, `File.stat`, `File.size`, or any `File::Stat` method; any cookbook Ruby calling `.zero?`.

**Detection**:

```bash
git grep -nE 'File\.(mtime|stat|size|birthtime|ctime|atime)' cookbooks/
git grep -nE '\.zero\?' cookbooks/
```

Any `File.*` hit inside a Proc, or any `.zero?` hit in recipe Ruby, is a mruby NoMethodError waiting to fire. (`.zero?` hits inside `files/` scripts run by CRuby are fine — check which runtime executes the file.)

Detail: see `~/.claude/docs/ruby-detail.md#mruby-file-api`.
