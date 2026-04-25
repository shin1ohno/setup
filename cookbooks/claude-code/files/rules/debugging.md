# Code Behavior Debugging Protocol

## Silent Failure Detection

A silent failure is when an operation returns success but the intended state change did not occur. Observable signals: API returns 200/Ok, function returns without error, but the expected effect (playback starts, file appears, record saved, remote device reacts) is absent.

When you cannot directly observe the effect of a fix from the source code alone:

1. **Build the observation tool first** — create a status command, add debug logging (env-gated is fine, e.g., `ROON_DEBUG=1`), or write a verification script *before* attempting the fix
2. **Capture baseline state** — observe the state before applying the fix so you have a reference
3. **Apply the fix**
4. **Re-observe** — confirm the state changed as expected
5. Only then report success to the user

## Do Not Report Success Without State Evidence

The following are NOT evidence that a fix worked:

- The code compiled and ran without errors
- The function returned `Ok(())` / resolved a Promise / exited 0
- A "success" or "Playing: X" message was printed by *your* code
- A previous run's output looked correct
- The test suite passes (unit/integration tests exercise isolated paths, not end-to-end effects)

The following ARE acceptable evidence:

- Observable system state on the receiving end (zone status, file exists, database record present, queue length changed)
- Test output that exercises the changed code path against real inputs
- Log output from the *receiving* system (not the sending side)
- A status-query command that returns the expected state after the fix

## When to Add Observation Tooling Proactively

Add a status/observe command *as part of the feature*, not as a follow-up, when:

- The operation crosses a network or IPC boundary (you send a command; a remote system executes it — MQTT, HTTP, WebSocket RPC, IPC)
- The operation is asynchronous (command sent now, effect occurs later)
- Previous fix attempts reported success but user confirmed the effect was absent
- The feature controls external hardware or services (audio systems, IoT devices, CI pipelines)

If no observation tool exists in the codebase yet, build a minimal one (`status` subcommand, `--verbose` flag, status query script) during the same unit of work.

## Do Not Push Error Reproduction to the User

The user asking "試してみてください" / "run it and check" is a fallback, not a default. Before reaching that fallback:

1. Reproduce the failure yourself using the observation tool
2. Verify your hypothesis about the cause (again via observation, not source reasoning)
3. Apply the fix
4. Verify the fix took effect (again via observation)
5. Report the fix to the user with the observed state-change as evidence

Asking the user to reproduce an error they already reported is asking them to do your debugging work.

## Fix-Loop Escalation Threshold

When the same observable symptom persists after 3 hypothesis-test cycles on the same code path, stop the fix loop. Do not start a 4th local fix.

Instead:
1. Synthesize the failed hypotheses: "3 approaches failed (A, B, C). The shared assumption is X."
2. Challenge X at the design level with AskUserQuestion: "これ以上の局所修正では解決しない可能性があります。設計上の前提 X を見直す必要があるかもしれません。どの方針で進めますか？"

**Signal**: same symptom after 3 cycles = wrong design assumption, not wrong implementation detail. Continuing to iterate on implementation is sunk-cost behavior.

## Read the Source Before Researching Patterns

When the failure is an observable error string from a third-party Rust / Go / Python SDK (e.g., `BLE error: Device not found`, `connection refused`, `unauthorized`), **grep the SDK source for the exact error string before launching a web-research sub-agent**.

Research-first agents surface authoritative-looking docs about the surrounding abstraction layer (OS permissions, network stack, wire protocol) that can mis-frame the problem. Source-first finds the line that emits the error and its guard condition in 1-2 minutes.

**Sequence**:

1. `find` / `Glob` the SDK repo on disk (`~/ManagedProjects/<sdk>/`). If absent, `cargo fetch` + inspect `~/.cargo/registry/src/` for the published version.
2. `Grep` for the error string — typically reveals a single emit site with a narrow failure condition.
3. Read the 30-50 lines around the emit site, trace the guard condition back to the API surface.
4. Form a hypothesis grounded in that source, **then** research if needed.

**Anti-signal**: if a research agent comes back with suggestions that rely on entire-layer replacements (e.g., ".app bundle + codesign + Info.plist entitlements" for a BLE error), and the SDK source hasn't been read, assume the framing is wrong. Read the source before acting on that research.

This rule exists because Thread 3 of the 2026-04-20 retro session burned ~30 minutes on macOS TCC / .app-bundle research for a `BLE error: Device not found`, when the actual bug was a 2-line sibling-central mismatch inside `nuimo-rs/crates/nuimo/src/backend/macos.rs` — visible on first read of the file.

### Custom terraform providers — apply-time command-string errors

This applies identically to custom Terraform providers. When `terraform apply` fails with a device-side syntax error (YAMAHA RTX `コマンド名を確認してください`, Cisco `% Invalid input`, a CLI-style "unrecognized command" from any provider), **grep the provider's command builders — `Build*Command`, `ToCommands`, `Render*`, the service layer that calls `executor.Run` — before trusting an Explore agent's summary or the provider's own `docs/`**.

The provider's internal schema and docs describe what the resource accepts; they do not always reflect what the code emits. The emitted string is what the device actually sees. A 2-minute grep for the exact command fragment in the error (e.g., `"ip tunnel"` for `ip tunnel1 secure filter ...`) usually points directly at the builder that needs fixing.

This rule exists because the 2026-04-22 session lost ~30 minutes after an Explore agent reported that `terraform-provider-rtx` supported tunnel-interface filter apply. The provider did expose the resource, but its `BuildInterfaceSecureFilterCommand` emitted `ip tunnel1 secure filter ...` which RTX rejects — the correct form requires a `tunnel select N` context switch first. Visible on first read of `internal/rtx/parsers/ip_filter.go`.

### Tool-manager migration design — verify backend claims before writing

The "read the source before researching" principle applies at design time too, not just during debugging. When designing a migration to a tool manager (mise / asdf / nix / homebrew) or writing any external-download recipe (`ubi:`, `aqua:`, `github:`, `go:`, `cargo:` backends; manual `curl` + `shasum` installs), treat plan-agent or web-search output as **unverified hypotheses, not facts**.

The authoritative sources are:

- `mise registry <name>` — confirms whether bare `mise use <name>` works and which backend the registry uses
- `gh api repos/<owner>/<repo>/releases/latest --jq '.tag_name, (.assets[] | .name)'` — confirms tag format and downloadable assets
- `curl -fsI <url>` — confirms the URL serves the expected file (always `-f`, never bare `-L`)
- `gh api repos/<owner>/<repo> --jq '.language'` — confirms the repo's primary language matches the planned backend (`go:` requires Go; `cargo:` requires Rust; `npm:` requires JS/TS)

Run each one before writing the cookbook line. Web summaries cannot detect:

- `ubi:` prepends `v` to the version, but upstream tag is bare `1.6.2` → 404
- `.sha256` file contains a bare hash; `shasum -c` expects `<hash>  <filename>` → error
- S3-hosted `-arm64`/`-x86_64` URLs return 403; only `-universal` is public
- GitHub Releases exists but has zero downloadable assets (tarball-only release)
- Tool is not in mise core registry; needs `aqua:<org>/<repo>` prefix
- Repo is Swift/Zig/not-Go; `go:` backend silently fetches wrong binary or fails

These all look identical from a plan-agent's web summary. They diverge only when you query the actual API or URL.

This rule exists because PR #32 (2026-04-25 brew→mise migration in `~/ManagedProjects/setup`) shipped 8 of these failure modes in a single PR, producing 6 cleanup PRs (#33, #34, #36, #37, #38, #41) over the same session. The full pre-migration checklist is in `~/.claude/rules/mise-migration.md`; the executable batch is the `/verify-mise-backend` skill.

## Frame the Failure Class Before Writing the Fix

When fixing a bug, the first design question is **"what shape is this failure class?"**, not "what minimal change makes this error stop?". Silencing the specific error often leaves the underlying fragility in place — correct only until the next instance.

**Triggers** — when the error involves any of these, the failure is almost certainly structural and deserves a failure-class framing pass before implementing:

- Hard-coded addresses (IPs, hostnames, ports) that the environment can rotate — DHCP leases, floating cloud IPs, mDNS-announced services
- Stored auth tokens or keys against a mutable endpoint — the credential is stable but the endpoint it points to is not
- Hard-coded filesystem paths that reference structure a sibling process / deploy step manages — `configs/*.toml` dropped by a repo refactor, state directories moved by an XDG migration, symlinks rewritten by deploys
- Timestamps, versions, or hashes embedded in persisted state that outlive their intended scope

**Protocol**:

1. Before implementing, name the failure class: "what set of similar failures will this same design reproduce?" Write it down in one sentence.
2. If the class is structural (multiple foreseeable triggers, not a one-off), propose the class-wide fix via AskUserQuestion — typically includes discovery / caching / fallback, not just silencing
3. If the class is transient (network blip, race, rare external outage), non-fatal retry is sufficient — proceed without the full framing round
4. Non-fatal + retry is a necessary piece of the structural fix, **never the complete fix**. A dead service retried against stale config will stay dead forever

**Anti-pattern**: seeing "Connection refused on 192.168.1.23" and immediately making the init non-fatal, without asking "why 192.168.1.23? is it stable? what happens when it changes?". The non-fatal change satisfies "error stops crashing the process" but leaves the service silently dead until a human re-pairs.

This rule exists because in the 2026-04-22 session, three cascaded "hard-coded stale value" failures — systemd ExecStart pointing at a deleted `configs/` path, stale release binary predating the config migration, and Hue token IP pinned to a rotated DHCP lease — would each have been caught by asking "is this value persistently hard-coded against a thing that rotates?" before starting implementation. Instead, each was discovered sequentially, wasting restart cycles.

## Chain verify command with the fix in the same `!` block

When presenting a credential or configuration fix to the user that must succeed before the main task can resume, **compose the verify command into the same `!` block** with `&&`:

```
! aws configure --profile sh1admn && \
  aws ssm get-parameter --name /ssh-keys/devices/neo/private \
    --with-decryption --profile sh1admn --region ap-northeast-1 > /dev/null && \
  echo OK
```

Versus the anti-pattern of presenting fix and verify as separate steps the user is expected to chain mentally:

```
! aws configure --profile sh1admn

# (then run, separately:)
! aws ssm get-parameter --name /ssh-keys/devices/neo/private ...
```

Users skip "separately" verifies, especially under time pressure or when the fix command "looks like" it succeeded. They go straight back to retrying the main task, which fails at a deeper layer with a different-looking error — burning 2-3 round-trips to re-diagnose what the verify would have caught instantly.

**When verify cannot be composed** (e.g. the fix is `aws configure` interactive, which can't be piped): explicitly mark the verify command as **required before retrying the main task** — not as a suggestion. Words like "and confirm with" or "before retrying, run". Not "you can also check".

This rule exists because the 2026-04-25 neo bootstrap session presented `aws configure --profile sh1admn` and the SSM-read verify as separate steps. The user configured the profile, skipped the verify, and re-ran mitamae — which then failed deeper (UnrecognizedClientException because the credentials had been clobbered by an earlier `aws configure set` with empty values). 4-5 round-trips of diagnostic followed.
