# Code Behavior Debugging Protocol

This file is the always-loaded summary. Long examples + origin notes are in `~/.claude/rules/debugging-detail.md` (NOT auto-imported — load on demand via Read tool when a section pointer matches the current task).

## Silent Failure Detection

A silent failure is when an operation returns success but the intended state change did not occur. Observable signals: API returns 200/Ok, function returns without error, but the expected effect (playback starts, file appears, record saved, remote device reacts) is absent.

When you cannot directly observe the effect of a fix from the source code alone:

1. **Build the observation tool first** — create a status command, add debug logging (env-gated is fine, e.g., `ROON_DEBUG=1`), or write a verification script *before* attempting the fix
2. **Capture baseline state** — observe the state before applying the fix so you have a reference
3. **Apply the fix**
4. **Re-observe** — confirm the state changed as expected
5. Only then report success to the user

## Noisy Non-Failure Pattern

The inverse of silent failure: a warning, error string, or health-check entry is visibly present, but the system is functioning correctly. Treating the noise as a defect can disable a fallback path the system depends on.

Protocol:

1. **Test the function the warning is about, end-to-end, before believing the warning** — `tailscale status` complains about DNS → run `getent hosts <peer>` and `tailscale ping <peer>` first
2. **Classify the noise**: Cosmetic (failed path the system already abandoned, safe to silence), Partial (degraded mode in effect, fix the real problem), Load-bearing (warning describes the actual broken behavior)
3. **Only Cosmetic noise is safe to silence** — verify the silence doesn't disable the working path
4. **State the classification to the user before proposing a fix**

Detail (trap explanation + origin): see `~/.claude/rules/debugging-detail.md#noisy-non-failure-pattern`.

## Do Not Report Success Without State Evidence

NOT evidence: code compiled/ran without errors; function returned `Ok(())`; "success" message printed by *your* code; previous run looked correct; test suite passes (unit/integration tests exercise isolated paths, not end-to-end effects).

ARE evidence: observable system state on the receiving end (zone status, file exists, DB record present, queue length changed); test output exercising the changed path against real inputs; log output from the *receiving* system; status-query command returning the expected state after the fix.

## Auth Gate Changes — Live Token Step Required

For a change to an authentication / authorization gate on a RUNNING system (JWT validator, nginx `auth_request`, bearer / API-key check, session-cookie validator, mTLS peer check), a source-level adversarial PASS is necessary but NOT sufficient evidence. Verification MUST include a live token round-trip:

1. Decode a real token from the actual live issuer (not a synthetic one) and confirm the new check passes for its real claim values.
2. After deploy, round-trip a real client request and observe accept/reject on the receiving system.

Synthetic-token tests encode your assumption about the token shape — the exact thing an auth tightening puts at risk. See the design-time counterpart in `~/.claude/rules/adversarial-review.md` "Live Token Round-Trip Gate". Origin: 2026-06-07 synthetic-token PASS, real `aud=[]`.

## When to Add Observation Tooling Proactively

Add a status/observe command *as part of the feature*, not as a follow-up, when:

- The operation crosses a network or IPC boundary (MQTT, HTTP, WebSocket RPC, IPC)
- The operation is asynchronous (command sent now, effect occurs later)
- Previous fix attempts reported success but user confirmed the effect was absent
- The feature controls external hardware or services (audio, IoT, CI pipelines)

If no observation tool exists in the codebase yet, build a minimal one (`status` subcommand, `--verbose` flag, query script) during the same unit of work.

## Auth-boundary error visibility — log Err variant on every reject

Authentication and authorization gates (JWT validators, OAuth bearer verifiers, `auth_request` handlers, API key checks, session cookie validators, mTLS peer cert checks) MUST log the rejection variant at WARN or ERROR level **unconditionally** — never gated behind `#[cfg(debug_assertions)]`, `RUST_LOG=trace`, `DEBUG=1`, or any flag that defaults off in production.

Trigger pattern: `verify_*` returns `Result<Claims, AuthError>` (rich enum); call site discards the variant via `Err(_) => return 401`. Fix: log `error_variant = ?e` + relevant config (`expected_iss`) before the response, OR move the log into the verify function itself at the final reject site.

**Don't** log the full token. **Do** log: variant, kid from JWT header, expected issuer/audience/scope, 16-char token prefix.

Server-side counterpart of "FFI Boundary Error Visibility" in `~/.claude/rules/ios-build.md`.

Detail (Rust example + origin): see `~/.claude/rules/debugging-detail.md#auth-boundary-error-visibility`.

## Do Not Push Error Reproduction to the User

The user asking "試してみてください" / "run it and check" is a fallback, not a default. Before reaching that fallback, run the observe→fix→re-observe loop yourself (Silent Failure Detection above): reproduce the failure via the observation tool, verify the cause via observation (not source reasoning), apply the fix, verify it took effect via observation, then report with the observed state-change as evidence.

Asking the user to reproduce an error they already reported is asking them to do your debugging work.

## Fix-Loop Escalation Threshold

When the same observable symptom persists after 3 hypothesis-test cycles on the same code path, stop the fix loop. Do not start a 4th local fix.

1. Synthesize the failed hypotheses: "3 approaches failed (A, B, C). The shared assumption is X."
2. Challenge X at the design level with AskUserQuestion: "局所修正では解決しない可能性がある。設計上の前提 X を見直す必要があるか？"

**Signal**: same symptom after 3 cycles = wrong design assumption, not wrong implementation detail.

**Batch fixes within a rebuild cycle**: when a debugging loop involves an expensive rebuild (`docker compose up --build`, `cargo build --release`, `xcodebuild`, `terraform apply` — anything >60s), collect ALL hypothesized fixes for the *current* observable failure before triggering the rebuild. Sequential evaluation of N hypotheses costs N × build time; batched evaluation costs one build.

Detail (worked example + origin): see `~/.claude/rules/debugging-detail.md#fix-loop-escalation-threshold`.

## Wire-Protocol Reverse Engineering — Capture Reference Bytes First

When implementing a transport, webhook receiver, or protocol endpoint to satisfy an external client whose format expectations are undocumented (Anthropic Claude.ai MCP connector, Slack RTM/Socket Mode, MCP client SDK, vendor webhook handshake), capture the *raw bytes* from a known-working reference server BEFORE writing any implementation code.

Sequence:

1. Identify the nearest working reference deployment (sibling vendor endpoint, open-source server, in-tree example — there is almost always one)
2. Capture the wire bytes:
   ```
   curl -sN -H "Accept: text/event-stream" '<reference-url>' | head -c 400 | xxd
   curl -sIL '<reference-url>'   # response headers
   ```
3. Write the implementation
4. Diff your output against the reference at the same hex-dump granularity:
   ```
   diff <(curl -sN '<reference>' | head -c 400 | xxd) \
        <(curl -sN '<new>'       | head -c 400 | xxd)
   ```
5. Fix every divergence in **one** batch (per Fix-Loop Escalation rule above)

**Trigger**: "the client says NG but my server returns 200 OK". The client has format expectations your code does not satisfy yet. Stop hypothesizing; start observing.

Detail (common divergence list + origin): see `~/.claude/rules/debugging-detail.md#wire-protocol-reverse-engineering`.

## Read the Source Before Researching Patterns

When the failure is an observable error string from a third-party Rust / Go / Python SDK (e.g., `BLE error: Device not found`, `connection refused`, `unauthorized`), **grep the SDK source for the exact error string before launching a web-research sub-agent**. Source-first finds the line that emits the error and its guard condition in 1-2 minutes.

Sequence:

1. `find` / `Glob` the SDK repo on disk (`~/ManagedProjects/<sdk>/`). If absent, `cargo fetch` + inspect `~/.cargo/registry/src/`
2. `Grep` for the error string — typically reveals a single emit site
3. Read 30-50 lines around the emit site, trace guard back to API surface
4. Form a hypothesis grounded in source, **then** research if needed

Sub-rules (Detail file): custom Terraform providers — apply-time command-string errors; tool-manager migration design — verify backend claims (cross-link to `~/.claude/rules/mise-migration.md`); CLI tool JSON output — probe schema before writing jq.

Detail (sub-rules + anti-signal + origins): see `~/.claude/rules/debugging-detail.md#read-the-source-before-researching`.

## Frame the Failure Class Before Writing the Fix

When fixing a bug, the first design question is **"what shape is this failure class?"**, not "what minimal change makes this error stop?". Silencing the specific error often leaves the underlying fragility in place.

**Triggers** — when the error involves any of these, the failure is structural and deserves a failure-class framing pass:

- Hard-coded addresses (IPs, hostnames, ports) that the environment can rotate — DHCP leases, floating cloud IPs, mDNS-announced services
- Stored auth tokens or keys against a mutable endpoint — credential stable but endpoint not
- Hard-coded filesystem paths referencing structure a sibling process / deploy step manages
- Timestamps, versions, or hashes embedded in persisted state outliving their intended scope

Protocol:

1. Before implementing, name the failure class in one sentence: "what set of similar failures will this same design reproduce?"
2. If structural (multiple foreseeable triggers), propose the class-wide fix via AskUserQuestion — typically discovery / caching / fallback, not just silencing
3. If transient (network blip, race, rare external outage), non-fatal retry suffices
4. Non-fatal + retry is a necessary piece of the structural fix, **never the complete fix** — a dead service retried against stale config stays dead

Detail (anti-pattern + origin): see `~/.claude/rules/debugging-detail.md#frame-the-failure-class`.

## Verify a chosen remediation is feasible before executing it

Distinct from **Verify-before-done** (post-fix state confirmation): this is a *pre-execute precondition* check. After AskUserQuestion settles on a remediation, run the cheapest probe that confirms the chosen path can actually work **before** running the destructive or expensive step. A user selecting an option does not make its precondition true.

Probe-before-execute pairs:

- "restore from snapshot" → `GET _snapshot/<repo>/_all` — is the target index actually in a snapshot, with a non-failed shard? — before the restore
- "cherry-pick that commit" → `git cat-file -e <hash>` / `git log <hash>` before the cherry-pick
- "restore from S3 / backup" → `aws s3 ls <bucket>/<key>` before the restore
- "roll back to version X" → confirm the tag / artifact exists before the rollback
- "reassign to user/role Y" → confirm Y exists with the needed grant before the change

If the precondition is absent, do NOT run the doomed command (it fails with a misleading error — "snapshot not found", "bad revision"). Return to the user with the corrected, actually-feasible options.

Origin: 2026-05-30 chosen snapshot-restore had zero snapshots.

## Chain verify command with the fix in the same `!` block

When presenting a credential or configuration fix to the user that must succeed before the main task can resume, **compose the verify command into the same `!` block** with `&&`:

```
! aws configure --profile sh1admn && \
  aws ssm get-parameter --name /ssh-keys/devices/neo/private \
    --with-decryption --profile sh1admn --region ap-northeast-1 > /dev/null && \
  echo OK
```

When verify cannot be composed (e.g. interactive `aws configure`): explicitly mark verify as **required before retrying the main task**, not a suggestion. "and confirm with" or "before retrying, run". Not "you can also check".

Detail (anti-pattern + origin): see `~/.claude/rules/debugging-detail.md#chain-verify-with-fix`.

## Confirm the suspected driver is actually deployed before optimizing it

Before designing an optimization or fix for a specific process / script / cron job suspected of driving a cost or load metric, run a one-shot probe to confirm it is actually present and running on the target host(s). Source-code existence does not imply deployment.

Probe sequence (30 seconds, avoids the full investigation arc on a ghost process):

```bash
ssh root@<host> "find /root /etc/cron.d /etc/cron.* /var/spool/cron -name '<pattern>' 2>/dev/null"
ssh root@<host> "pgrep -a -f '<script-name>' || echo NOT_RUNNING"
ssh root@<host> "grep -rs '<script-name>' /etc/cron* /var/spool/cron || echo NO_CRON"
ssh root@<host> "systemctl list-timers --all | grep '<name>' || echo NO_TIMER"
```

If all return absent / NOT_RUNNING / NO_CRON / NO_TIMER, the suspected driver is not active on the target. Stop optimizing it and pivot to finding the actual driver (CloudTrail, `ps aux`, container logs, `systemctl list-timers`).

**Trigger**: you are about to implement a cache, throttle, or rate-limit for a specific script or service based on source-code reading, without having verified it runs on the target.

Origin: 2026-06-10 optimized a script not deployed on target.
