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
