# Code Behavior Debugging Protocol

Always-loaded summary; examples + origins in `~/.claude/docs/debugging-detail.md` (on-demand).

## Silent Failure Detection

Silent failure = success returned (200/Ok) but the intended effect is absent. When the effect is not visible from source: (1) build the observation tool first (status command, env-gated debug log, verify script), (2) capture baseline, (3) fix, (4) re-observe, (5) only then report success.

## Noisy Non-Failure Pattern

Inverse: a warning is present while the system works; "fixing" it can kill a fallback. (1) Test the warned-about function end-to-end first (DNS warning → `getent hosts <peer>`, `tailscale ping <peer>`). (2) Classify: Cosmetic (abandoned path) / Partial (degraded — fix the real problem) / Load-bearing (real breakage). (3) Silence only Cosmetic, keeping the working path. (4) State the classification before proposing a fix.

Detail: see `~/.claude/docs/debugging-detail.md#noisy-non-failure-pattern`.

## Do Not Report Success Without State Evidence

NOT evidence: clean compile/run, `Ok(())`, your own code's "success" line, a previous good run, passing tests, green CI whose exercising step is gated on `workflow_dispatch` inputs (grep its `if:`; if gated, dispatch it and read that step's conclusion and stdout). ARE evidence: receiving-end state (file, DB record, zone status, queue length), tests on the changed path with real inputs, receiving-system logs, a status query showing the expected state.

Detail: see `~/.claude/docs/debugging-detail.md#do-not-report-success-without-state-evidence`.

## Auth Gate Changes — Live Token Step Required

For an auth-gate change on a RUNNING system (JWT, `auth_request`, bearer/API key, session cookie, mTLS), a source-level adversarial PASS is necessary but NOT sufficient. MUST also: (1) decode a real token from the live issuer and confirm the check passes its real claims; (2) after deploy, round-trip a real request and observe accept/reject on the receiving system. Design-time counterpart: `adversarial-review.md` "Live Token Round-Trip Gate".

Detail: see `~/.claude/docs/debugging-detail.md#auth-gate-changes-live-token`.

## When to Add Observation Tooling Proactively

Ship a status/observe command *with the feature* when it crosses a network/IPC boundary, is async, controls external hardware/services, or earlier fixes "succeeded" with no visible effect. If none exists, build a minimal one in the same unit of work.

## Adapter layers need tests with host-shaped input

A thin adapter over tested logic (n8n Code node, Lambda handler, webhook controller, CLI parser) needs its own test with the input shape the host actually delivers, asserting what it passes on. When a plan tests only the logic layer, name the adapter tier as a plan gap before implementing. Same class as `docs/ffi-audit.md`.

Detail: see `~/.claude/docs/debugging-detail.md#adapter-layers-host-shaped-input`.

## Auth-boundary error visibility — log Err variant on every reject

Auth gates MUST log the rejection variant at WARN/ERROR **unconditionally**, never behind a default-off flag (`cfg(debug_assertions)`, `RUST_LOG=trace`, `DEBUG=1`). Trigger: `Err(_) => return 401` discarding a rich error enum — log `error_variant = ?e` + expected config, at the call site or the final reject site. Never the full token; do log variant, kid, expected iss/aud/scope, 16-char prefix.

Detail: see `~/.claude/docs/debugging-detail.md#auth-boundary-error-visibility`.

## Do Not Push Error Reproduction to the User

"試してみてください" is a fallback, not a default. Reproduce, confirm the cause, fix and verify by observation yourself, then report with the observed state change.

## Fix-Loop Escalation Threshold

Same symptom after 3 hypothesis-test cycles on one path → stop, no 4th local fix. Synthesize ("A, B, C failed; shared assumption X") and ask via AskUserQuestion: "局所修正では解決しない可能性がある。設計上の前提 X を見直す必要があるか？". Count by capability, not error text — differently-worded errors on one capability still count. When each try costs a >60s rebuild, batch all hypothesized fixes into one rebuild.

Detail: see `~/.claude/docs/debugging-detail.md#fix-loop-escalation-threshold`.

## Wire-Protocol Reverse Engineering — Capture Reference Bytes First

When an external client's format is undocumented (MCP connector, Slack Socket Mode, vendor webhook), capture raw bytes from a working reference server BEFORE implementing, hex-diff your output against it, and fix all divergences in one batch. Trigger: "client says NG, my server returns 200".

Detail: see `~/.claude/docs/debugging-detail.md#wire-protocol-reverse-engineering`.

## Read the Source Before Researching Patterns

For a third-party SDK error string, **grep the SDK source for it before any web research** (`~/ManagedProjects/<sdk>/`, else `~/.cargo/registry/src/`), read 30-50 lines around the emit site, trace the guard, then hypothesize. Sub-rules (Terraform provider command strings, tool-manager backend claims, CLI JSON schema before jq) in Detail.

Detail: see `~/.claude/docs/debugging-detail.md#read-the-source-before-researching`.

## Frame the Failure Class Before Writing the Fix

Ask "what failure class is this?" before "what stops this error?". Structural triggers: rotating addresses, stored tokens against a mutable endpoint, paths another process manages, timestamps/versions/hashes outliving scope. Structural → propose the class-wide fix (discovery/caching/fallback) via AskUserQuestion; transient → retry suffices. Retry alone never completes a structural fix.

Detail: see `~/.claude/docs/debugging-detail.md#frame-the-failure-class`.

## Verify a chosen remediation is feasible before executing it

After AskUserQuestion picks a remediation, run the cheapest probe proving its precondition **before** the destructive/expensive step (snapshot, commit, backup, tag, role exists; credential is not a shared rotating token; device identified by a per-device identifier). Absent → do not run it; return with feasible options.

Detail: see `~/.claude/docs/debugging-detail.md#verify-remediation-feasible`.

## Chain verify command with the fix in the same `!` block

Compose a must-succeed credential/config fix with its verify in one `!` block via `&&`. If not composable (interactive `aws configure`), mark the verify **required before retrying the main task**, never optional.

Detail: see `~/.claude/docs/debugging-detail.md#chain-verify-with-fix`.

## Confirm the suspected driver is actually deployed before optimizing it

Before caching/throttling a script suspected from source of driving cost or load, probe the target: `find`, `pgrep -a -f`, crontabs, `systemctl list-timers --all`. All absent → find the real driver (CloudTrail, `ps aux`, container logs).

Detail: see `~/.claude/docs/debugging-detail.md#confirm-suspected-driver-deployed`.
