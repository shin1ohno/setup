# Code Behavior Debugging — Examples & Origin Notes

This file is the detail companion to `~/.claude/rules/debugging.md`. The summary file holds the rule statements and minimal protocol; this file holds the long-form examples, anti-patterns, and origin paragraphs that the model reads on demand.

Anchor convention: each section's heading slug matches the pointer line in the summary file.

## auth-gate-changes-live-token

Synthetic-token tests encode your assumption about the token shape — the exact thing an auth tightening puts at risk. A synthetic token you mint reflects the claim shape you *expect*; the live issuer may mint something different (e.g. an empty `aud=[]`), so only a real token round-trip confirms the new check passes for the values actually issued.

Origin: 2026-06-07 synthetic-token PASS, real `aud=[]`.

## do-not-report-success-without-state-evidence

Green CI is not evidence when the step that would exercise your change is gated behind `workflow_dispatch` inputs: `github.event.inputs.*` is empty on `pull_request`, so an `if: github.event.inputs.test_level == '…'` step silently skips and still contributes to the green checkmark. Before writing "CI verifies X" in a PR body or commit message, grep the workflow YAML for the `if:` on the specific step that exercises X; if it is input-gated, dispatch it (`gh workflow run <wf> --ref <branch> -f <input>=<value>`) and read that step's conclusion AND its real stdout — `gh run watch --exit-status` exits 0 for a skipped step too.

Unit/integration tests exercise isolated paths, not end-to-end effects, which is why a passing suite is not state evidence either.

Origin: 2026-08-02 setup #793 — a PR body claimed `test-macos` gated a darwin change while its apply/verify steps had not run.

## adapter-layers-host-shaped-input

Unit tests on the wrapped logic say nothing about the wrapper: the logic can be correct while every call site passes it the wrong shape. Name the missing adapter tier as a plan gap before implementation, not as a review finding after it.

Origin: 2026-09-26 — 390 passing unit tests on the logic layer, while five Code-node adapters passed the wrong input shapes (one would have blocked every promotion); found only at review.

## noisy-non-failure-pattern

The trap: warning-driven debugging starts from "this looks broken, fix it" and skips the function test. The fix often disables the OS feature that was holding things together. Function-test first, classify the noise, then act.

This rule exists because the 2026-04-26 session correctly applied this protocol on a tailscale resolvconf warning — DNS was verified working before the divert was proposed. Codifying the approach so it generalizes.

## auth-boundary-error-visibility

The pattern that triggers this rule: a `verify_*` or `authenticate_*` function returns `Result<Claims, AuthError>` (or equivalent) where `AuthError` is a rich enum (`WrongIssuer`, `WrongAudience`, `Expired`, `InvalidSignature`, `Other(String)`, etc.), and the call site discards the variant — emitting a flat HTTP 401 / 403 with no log line that names which variant fired.

```rust
// WRONG — silent: every rejection looks identical to the operator
match verify_bearer(header, &cache, &cfg).await {
    Ok(claims) => /* ... */,
    Err(_) => return unauthorized_response(),
}

// RIGHT — variant + relevant claim values logged before the response
match verify_bearer(header, &cache, &cfg).await {
    Ok(claims) => /* ... */,
    Err(e) => {
        tracing::warn!(
            error_variant = ?e,
            error = %e,
            expected_iss = %cfg.issuer,
            "auth rejected"
        );
        return unauthorized_response();
    }
}
```

Or place the `tracing::warn!` inside the verify function itself at the final reject site, so every caller benefits without coordinated changes.

The cost of a silent auth gate: every wrong-token / wrong-issuer / expired-token / kid-not-in-jwks failure looks identical to the operator (a 401 with the same body). Diagnosing requires a debug build with added logging, deploy, retry, decode logs — typically 30+ minutes per session. With unconditional logging the diagnosis is one `docker logs ... | grep "auth rejected"` away.

**Don't** log the full token (logs end up in centralized aggregation; tokens are credentials). DO log: the variant, the kid extracted from the JWT header, the expected issuer/audience/scope from server config, a 16-char token prefix to disambiguate concurrent requests. Never the full Authorization header value.

This rule is the server-side counterpart to the iOS rule "FFI Boundary Error Visibility" (`~/.claude/docs/ios-build.md`) — both codify that the boundary between trusted-caller and untrusted-input must surface its rejection variant, not just its rejection.

This rule exists because roon-mcp's `verify_bearer` (in `crates/roon-mcp/src/auth.rs`) returned `Result<Claims, AuthError>` with rich variants but the call site at /sse just emitted HTTP 401 invalid_token — every reject looked identical. The 2026-05-05 session debug arc spanned PR #128 (RUST_LOG=info,roon_mcp::auth=debug, no effect because the Err arm had no debug! either), through the present session's debug branch with added `tracing::warn!` at line 240, before the actual variant (`AuthError::WrongAudience`) was visible. With unconditional logging the diagnosis would have been minutes, not the 3-session arc it became.

## fix-loop-escalation-threshold

**Signal**: same symptom after 3 cycles = wrong design assumption, not wrong implementation detail.

**Count by capability, not by error text**: when 3+ cycles chase the same *capability* ("make GPG signing work unattended", "get this secret readable from the box") but each cycle's error message differs, do NOT reset the counter because the symptom changed shape. Ask instead: do these differently-worded errors share one root assumption? A drifting error message is the normal look of a wrong assumption being probed from different angles. Origin: 2026-08-01 sh1-cloud — 5 cycles on unattended GPG signing (`No secret key` → protected-export silently dropping the subkey → `--passwd` targeting a stub primary → agent `Bad passphrase` → broken temp keyring), all resting on "an interactive passphrase flow is available"; the same-symptom counter never fired because no two errors matched.

**Batch fixes within a rebuild cycle**: when a debugging loop involves an expensive rebuild (`docker compose up --build`, `cargo build --release`, `xcodebuild`, `terraform apply` — anything that takes more than ~60s end to end), collect ALL hypothesized format / config fixes for the *current* observable failure before triggering the rebuild. Do not submit one change, wait for the build, observe the same-class failure, then submit a second change.

If 3 hypotheses each have 50/50 odds and the rebuild costs 5 min, sequential evaluation costs ~15 min plus mental context switching; batched evaluation costs ~5 min and forces you to enumerate the candidate space up front. Exception: when the second fix genuinely depends on observing the first fix's partial effect (e.g. you cannot guess header B's value without seeing the connection survive header A's wrong value first). When in doubt, batch.

This rule exists because the 2026-04-28 roon-mcp / SSE session ran ~7 docker rebuild cycles back-to-back — each cycle added one of {snake_case session_id, trailing slash on `/messages/`, `X-Accel-Buffering: no` header, `charset=utf-8` on content-type, default `sse_path = "/sse"`} — every one of which was diagnosable from the same `curl --hex-dump` against the cognee reference server before the first rebuild. ~35 minutes of build wall-clock recoverable by batching.

## wire-protocol-reverse-engineering

Sequence: (1) identify the nearest working reference deployment (sibling vendor endpoint, open-source server, in-tree example — there is almost always one); (2) capture the wire bytes; (3) write the implementation; (4) diff at hex-dump granularity; (5) fix every divergence in **one** batch (per Fix-Loop Escalation). The client has format expectations your code does not satisfy yet — stop hypothesizing, start observing.

Capture the reference wire bytes before writing any implementation:

```
curl -sN -H "Accept: text/event-stream" '<reference-url>' | head -c 400 | xxd
curl -sIL '<reference-url>'   # response headers
```

Diff your output against the reference at the same hex-dump granularity:

```
diff <(curl -sN '<reference>' | head -c 400 | xxd) \
     <(curl -sN '<new>'       | head -c 400 | xxd)
```

**Anti-pattern**: iterating on format hypotheses one-at-a-time across expensive rebuilds without ground truth. Common divergences hex-dump catches in one pass:

- LF vs CRLF line endings
- `event:` named events vs unnamed `data:`-only frames
- Path conventions (`/messages` vs `/messages/`, `sessionId=` vs `session_id=`)
- Required intermediary-control headers (`X-Accel-Buffering: no`, `Cache-Control: no-store`, charset)
- URL shape in payload (relative vs absolute, with or without proxy prefix)

This rule exists because the 2026-04-28 roon-mcp SSE session burned ~35 min iterating on SSE format hypotheses before running a single hex-diff against the cognee reference server. The diff revealed all five divergences in one pass.

## read-the-source-before-researching

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

This rule exists because PR #32 (2026-04-25 brew→mise migration in `~/ManagedProjects/setup`) shipped 8 of these failure modes in a single PR, producing 6 cleanup PRs (#33, #34, #36, #37, #38, #41) over the same session. The full pre-migration checklist is in `~/.claude/docs/mise-migration.md`; the executable batch is the `/verify-mise-backend` skill.

### CLI tool JSON output — probe schema before writing jq

When a CLI tool offers a JSON-output flag (`--json-output`, `--json`, `-o json`, `--format json`), NEVER write a jq selector against guessed key paths. Probe the actual shape first.

**Sequence**:

1. Run the command once with the JSON flag and pipe through `python3 -m json.tool | head -50` (or `jq '.' | head -50` if jq is available). Inspect the actual nesting and key names.
2. Read off the exact path you need.
3. Only then write the jq selector.

**Anti-pattern (from 2026-04-28 weave session)**:
- Guessed `xcrun devicectl list devices --json-output -` would expose `.result.devices[].hardwareProperties.platform` matching `"iPadOS"`.
- Actual JSON nested differently; selector returned empty.
- Next step became "please copy-paste the UDID" — pushing onto the user what a 2-second probe would have answered.

**Faster alternative — skip JSON entirely**: if the default tabular output already contains what you need, parse columns with awk:

```sh
xcrun devicectl list devices | awk '/iPad/ {print $3}'   # Identifier column for any device matching iPad
gh pr list --state open | awk -F'\t' '{print $1}'        # PR number column
```

For tools whose tabular output has stable column counts (most do), awk is shorter, more obvious, and impossible to break with a wrong jq selector.

**Same principle covers**: `gh api`, `aws ... --output json`, `kubectl get ... -o json`, `terraform show -json`, `cargo metadata --format-version 1`. Probe shape, then query.

## frame-the-failure-class

**Anti-pattern**: seeing "Connection refused on 192.168.1.23" and immediately making the init non-fatal, without asking "why 192.168.1.23? is it stable? what happens when it changes?". The non-fatal change satisfies "error stops crashing the process" but leaves the service silently dead until a human re-pairs.

This rule exists because in the 2026-04-22 session, three cascaded "hard-coded stale value" failures — systemd ExecStart pointing at a deleted `configs/` path, stale release binary predating the config migration, and Hue token IP pinned to a rotated DHCP lease — would each have been caught by asking "is this value persistently hard-coded against a thing that rotates?" before starting implementation. Instead, each was discovered sequentially, wasting restart cycles.

## verify-remediation-feasible

Probe-before-execute pairs:

- "restore from snapshot" → `GET _snapshot/<repo>/_all` — is the target index actually in a snapshot, with a non-failed shard? — before the restore
- "cherry-pick that commit" → `git cat-file -e <hash>` / `git log <hash>` before the cherry-pick
- "restore from S3 / backup" → `aws s3 ls <bucket>/<key>` before the restore
- "roll back to version X" → confirm the tag / artifact exists before the rollback
- "reassign to user/role Y" → confirm Y exists with the needed grant before the change
- "share one subscription/login across two hosts" → inspect the credential file's token structure for rotating-refresh-token semantics BEFORE copying it (in full below)
- "block / restrict a device" identified from a rotating or shared signal (a private MAC, a DHCP host name, an mDNS name) → confirm WHICH device it is with a per-device identifier (the AirPlay TXT `pi` over unicast mDNS, the model, or the owner's own confirmation) BEFORE merging or applying the block, not after. A MAC that appeared right after the old one vanished is a hypothesis; household Macs often share one name. Origin: 2026-10-03 home-monitor #170 blocked `.68` before the mDNS probe showed `Shinichi-Ohnos-MacBook-Air.local`, the same name as the operator's own Mac; the owner confirmed it was ann's Mac only afterwards.

A doomed command fails with a misleading error ("snapshot not found", "bad revision"), which is why the probe comes first.

The "share one subscription/login across two hosts" probe-before-execute pair, in full: inspect the credential file's token structure (`accessToken`/`refreshToken`/`expiresAt`) for rotating-refresh-token semantics BEFORE copying it — a shared rotating token invalidates whichever host refreshes second; the correct mechanism is an independent login per host (see `~/.claude/docs/claude-cli-headless.md`). Origin: 2026-07-04 memory-v2 keeper — probing the token structure surfaced the refresh-rotation conflict before building; a separate `claude setup-token` per host was the fix.

Origin: 2026-05-30 chosen snapshot-restore had zero snapshots.

## chain-verify-with-fix

Composed form — fix and verify in one `!` block so the user cannot skip the verify:

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

## confirm-suspected-driver-deployed

Probe sequence (30 seconds, avoids the full investigation arc on a ghost process):

```bash
ssh root@<host> "find /root /etc/cron.d /etc/cron.* /var/spool/cron -name '<pattern>' 2>/dev/null"
ssh root@<host> "pgrep -a -f '<script-name>' || echo NOT_RUNNING"
ssh root@<host> "grep -rs '<script-name>' /etc/cron* /var/spool/cron || echo NO_CRON"
ssh root@<host> "systemctl list-timers --all | grep '<name>' || echo NO_TIMER"
```

Origin: 2026-06-10 optimized a script not deployed on target.
