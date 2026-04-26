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
