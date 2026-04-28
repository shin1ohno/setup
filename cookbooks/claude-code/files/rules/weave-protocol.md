# Weave Protocol Publish Conventions

When adding a new property to the edge → weave-server publish path (`EdgeToServer::ServiceState` / `DeviceState`), the server-side `FeedbackPlan::resolve` and `FeedbackPlan::from_rules` impose a shape contract that is not enforced by the type system. Mismatches surface only at LED feedback testing time — well after the publish change has already shipped.

## The contract

`FeedbackPlan::from_rules` (see `crates/edge-agent/src/main.rs` and the iOS port in `weave-ios-core/src/feedback_pump.rs`) accepts a `StateUpdate { property, value, … }` and a list of mapping-level `FeedbackRule`s. It binds when:

- `rule.state == update.property` (top-level property name match)
- For `feedback_type: "glyph"`: `update.value` MUST be a `serde_json::Value::String`. The string is keyed into `rule.mapping` to find the glyph name.
- For `feedback_type: "volume_bar"`: `update.value` MUST be either a `Value::Number` or a Roon-style `{value, min, max, type?}` object. Anything else falls through.

If `update.value` is a nested object containing the relevant scalars (e.g. `{state: "playing", volume: 47.5}` under `property: "now_playing"`), the rule never binds — neither `from_rules` arm matches the shape. The plan falls through to `from_default`, which only handles the hardcoded property names `playback`, `volume`, `brightness`. A composite `now_playing` property therefore produces NO feedback at all.

## When this rule fires

You're adding code that calls one of:

- `EdgeClient::publish_*` (Rust)
- `weave_engine::push_state` (server-side)
- equivalent direct WS sends targeted at `/ws/edge`

Or: you're designing the JSON shape for a new edge state stream (Apple Music now-playing, smart home device snapshots, etc.).

## What to do

1. **Decompose composite state into separate properties.** A feature that covers "playback state + volume + track metadata" publishes THREE properties, not one:
   - `property: "playback"`, value `"playing" | "paused" | "stopped"` — string for glyph rules
   - `property: "volume"`, value `0..=100` number — for volume_bar rules
   - `property: "now_playing"`, value `{title, artist, …}` object — for UI-display only, not feedback

2. **Match wire-format property names to the FeedbackRule expectations.** Don't invent a new name when an existing one works. `playback` is the canonical name across Roon and iOS; `volume` matches both Roon zones and Hue brightness rules; `brightness` matches Hue. Use those.

3. **Test the publish shape against `FeedbackPlan::resolve` before merging.** The unit tests in `feedback_pump::tests` and `main.rs::feedback_plan_*_tests` cover the resolution path — write a new `from_rules_*_resolves_to_*_for_<your_property>` test that wires a representative `StateUpdate` through and asserts the right `FeedbackPlan` variant. If your test fails, the publish shape is wrong.

4. **For numeric scales: 0..=100 over 0.0..=1.0.** weave-web's `extractLevel` and `volume_bar_from_value` both expect 0..=100 percentages (Roon convention). If your underlying API gives 0..=1.0 (e.g. `AVAudioSession.outputVolume`), multiply by 100 at the publish boundary, not in the consumer.

5. **Keep the composite stream too — for UI display.** Splitting publishes into per-property frames doesn't replace the composite UI payload. Both have value: scalar properties drive feedback, composites drive rich UI cards. Just don't expect the composite to also drive feedback.

## Origin

This rule exists because the 2026-04-26 iOS session shipped PR #50 / #52 publishing all of `state`, `volume`, `title`, `artist` under a single `property: "now_playing"` whose value was a JSON object. The user had configured Roon-style feedback rules (`{"state": "playback", "feedback_type": "glyph", "mapping": {"playing": "play", …}}`) which were structurally correct but never matched, because the property name and value type didn't line up. Discovery happened only when LED feedback testing returned a dark Nuimo. PR #54 fixed it by splitting into three separate publishes — at the cost of a follow-up PR that could have been avoided by checking the shape at PR #50 design time.

# Cross-edge Dispatch — Capability Advertisement vs Runtime Readiness

`Hello.capabilities` is a **compile-time** flag — `cfg!(feature = "hue")`, `cfg!(feature = "roon")`, etc. It declares "this binary *can* connect to the adapter." It does **not** declare "this binary *is currently authenticated and dispatching*." The two diverge whenever:

- The adapter's pairing token is missing (e.g. `hue-token.json` not present on the host)
- The adapter's network target is unreachable (Roon Core down, Hue Bridge offline)
- The adapter is mid-boot (capability announced before adapter task spawns successfully)

When designing **cross-edge dispatch logic** (`weave-server`'s `find_edge_for_service`, MQTT routing target selection, anything that picks an edge from a pool), do **not** treat capability presence as proof of dispatch readiness.

## Selection guidance

**Prefer**, in order:
1. Edge that has emitted a recent successful `Command { result: Ok }` for the same `service_type` — observable proof the adapter dispatched something
2. Edge with the highest reported `version` — newer binaries are more likely to have the receive-side handler for newer `ServerToEdge` variants
3. Alphabetical `edge_id` as a deterministic tiebreak

**Avoid**:
- HashMap iteration order (non-deterministic, picks randomly between healthy and broken edges)
- Static config like "always pick pro" (brittle when topology changes)

## Failure handling

When a forwarded intent fails on the target edge (deserializer rejects unknown variant, adapter returns auth error, edge disconnects mid-dispatch), the server should:

1. **Log the failure class** with `source_edge`, `target_edge`, `service_type`, and the exception type
2. **Try the next capable edge** in the preference order, if one exists
3. **Surface the failure to `/ws/ui`** as `UiFrame::Command { result: Err { message } }` so the user sees the reason in the live console — not just "the press did nothing"

A silent dispatch drop is worse than a visible error: the user sees their hardware press and observes no reaction, with no diagnostic on screen. The `Err` frame anchors the failure to a wallclock moment and surfaces the error class.

## Edge-agent improvement (deferred)

Long-term: edge-agent should announce capabilities **based on runtime adapter state**, not just compile-time features. A `hue` capability should be advertised only after `hue-token.json` loads and the adapter task reports ready. Until that change ships, the server-side selection logic above is the workaround.

## Origin (cross-edge)

This section exists because the 2026-04-27 cross-edge intent forwarding session forwarded an iPad-routed Hue intent to neo (which advertised `hue` capability via `cfg!(feature = "hue")` but had no `hue-token.json`). The forwarded intent silently failed on neo because (a) neo was on edge-agent v0.8.0 and couldn't deserialize `ServerToEdge::DispatchIntent`, and (b) even after a 0.10.0 upgrade, neo's runtime hue adapter would have failed to dispatch. The user observed "press the Nuimo, Hue light doesn't react" with no UI signal explaining why. Recovery required killing neo's edge-agent + adding version-preference to `find_edge_for_service` + plus this rule.
