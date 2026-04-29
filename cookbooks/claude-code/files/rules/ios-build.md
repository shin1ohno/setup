# iOS Build Guidelines (XcodeGen + Rust UniFFI)

Conventions for the `weave-ios-core` / `WeaveIos` toolchain (and any sibling repo that uses XcodeGen + a Rust staticlib via UniFFI). These rules collect the prerequisites that surface as separate errors on a fresh Mac, so a future setup avoids walking the same staircase one step at a time.

## XcodeGen is the source of truth

If the iOS project has a `project.yml` next to `<App>.xcodeproj/`, the project file is **regenerated** by `xcodegen` from that YAML. Treat `<App>.xcodeproj/project.pbxproj` as a build artifact:

- ❌ Do not edit `project.pbxproj` directly. The next `xcodegen generate` overwrites the change silently.
- ❌ Do not edit `WeaveIos/Info.plist` directly when `project.yml` declares an `info.properties` block — the plist is regenerated from it.
- ✅ All Info.plist keys go under `targets.<name>.info.properties` in `project.yml` (e.g. `NSAppleMusicUsageDescription`, `NSBluetoothAlwaysUsageDescription`).
- ✅ All build settings go under `targets.<name>.settings` (e.g. `DEVELOPMENT_TEAM`, `IPHONEOS_DEPLOYMENT_TARGET`).
- ✅ After editing `project.yml`, run `cd ios && xcodegen` to regenerate.

`.gitignore` already excludes `*.xcodeproj/` and the regenerated Info.plist; honor that exclusion rather than trying to track the artefacts.

## CLI build prerequisites on a fresh Mac

Building the iOS app from CLI (typically over SSH from a Linux dev box to a Mac builder) discovers prerequisites in order, each as a different cryptic error. Do all four upfront on a fresh Mac:

### 1. PATH for non-interactive SSH

`ssh host '<command>'` invokes a non-interactive shell which loads `.zshenv` only — NOT `.zshrc`. Tools installed via `cargo` / `brew` / `mise` won't be on `PATH` unless you either (a) add `export PATH=$HOME/.cargo/bin:/opt/homebrew/bin:$PATH` to `~/.zshenv`, or (b) prefix every SSH command with `export PATH=...`.

In practice, prefix in command (b) is more robust against future toolchain changes:

```sh
ssh neo.local 'export PATH=$HOME/.cargo/bin:/opt/homebrew/bin:$PATH && cargo ...'
```

Tools commonly missing without this: `cargo` (rust), `brew` (Homebrew), `xcodegen`, `mise`, `node`/`npm` (when installed via mise/asdf).

### 2. Rustup iOS targets

`build-xcframework.sh` builds for three iOS targets (`aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios`). On a fresh Mac these are not installed — the script's preflight guard fails with one clear line per missing target:

```
ERROR: missing rustup target: aarch64-apple-ios
Run: rustup target add aarch64-apple-ios
```

Run the suggested command. The guard is in `ios/build-xcframework.sh` (added 2026-04-26).

### 3. `DEVELOPMENT_TEAM` for CLI codesign

Xcode's CLI build (`xcodebuild`) cannot resolve the signing team from interactive Xcode preferences — it needs an explicit value. Two ways:

- **Persistent (preferred)**: add `DEVELOPMENT_TEAM` to `project.yml`'s `targets.<name>.settings`:
  ```yaml
  targets:
    WeaveIos:
      settings:
        DEVELOPMENT_TEAM: AL9567565U
  ```
- **One-off**: pass on the xcodebuild command line:
  ```
  xcodebuild ... DEVELOPMENT_TEAM=AL9567565U build
  ```

Without it, xcodebuild fails with `Signing for "<App>" requires a development team. Select a development team in the Signing & Capabilities editor.`

### 4. Keychain unlock for codesign

After Swift compile completes, `codesign` reads the developer certificate from the **login keychain**. SSH sessions do not unlock the login keychain — codesign fails with:

```
errSecInternalComponent
Command CodeSign failed with a nonzero exit code
```

Unlock interactively in the user's terminal (so they can type the password to the prompt):

```
! ssh -t neo.local 'security unlock-keychain ~/Library/Keychains/login.keychain-db && \
  xcodebuild -project ... build && \
  xcrun devicectl device install app --device <id> <app-path> && \
  xcrun devicectl device process launch --device <id> <bundle-id>'
```

Compose the unlock + build + install + launch into one chain (per the debugging.md "compose verify with fix" rule) so the user runs one `!` block instead of four. The keychain stays unlocked for the rest of that SSH session and idle-locks again later — re-running the chain on next session is normal.

## macOS launchd `.app` bundle binary update

When the macOS edge-agent (or any launchd-managed service installed via the cookbook's `.app` bundle pattern) needs a binary update, `cargo install` alone is **not** sufficient — the launchd plist's `Program` path points at the bundle, not at the cargo bin.

```
launchctl list com.shin1ohno.edge-agent | grep -E 'Program|PID'
# "Program" = "/Users/<user>/Applications/EdgeAgent.app/Contents/MacOS/edge-agent"
# "PID" = ... (or "LastExitStatus" if not running)

ls -la ~/.cargo/bin/edge-agent ~/Applications/EdgeAgent.app/Contents/MacOS/edge-agent
# mtimes diverge after `cargo install` — the cargo bin is fresh, the bundle binary is stale
```

**Update protocol** (when not running mitamae):

1. `cargo install edge-agent --version <ver> --features <set> --locked` — refresh the cargo bin
2. `cp ~/.cargo/bin/edge-agent ~/Applications/EdgeAgent.app/Contents/MacOS/edge-agent` — overwrite the bundle binary
3. `launchctl kickstart -k gui/$(id -u)/com.shin1ohno.edge-agent` — terminate + respawn
4. Verify the running version: tail the agent's stdout/stderr log AND check `weave-server` connect logs for the new version string

**Preferred path**: run mitamae cookbook on the Mac. The recipe performs the cp + kickstart as part of the resource ordering. `cargo install` alone is never the complete operation for `.app`-bundled launchd services.

**`OnDemand=true` in the plist** does not auto-respawn after a SIGKILL. After `pkill -f cargo/bin/edge-agent` or similar, the service stays down until `launchctl start` (or the next demand trigger). Don't assume launchd will restart the service — verify with `launchctl list` and an explicit `launchctl start` if `LastExitStatus` is set and `PID` is absent.

This rule exists because the 2026-04-27 cross-edge session ran `cargo install edge-agent@0.10.0` on neo expecting the running service to pick up 0.10.0 on the next reconnect. The cargo bin updated but the launchd plist still pointed at the unmodified `.app` bundle, so neo reconnected to weave-server still announcing version 0.8.0 — invisible until the cross-edge dispatch routed a `ServerToEdge::DispatchIntent` to neo and the 0.8.0 deserializer dropped it. Two diagnostic turns lost finding the version mismatch.

## Putting it all together

A clean fresh-Mac bootstrap, in order:

```sh
# Once per Mac:
brew install xcodegen
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios

# Once per project:
cd ios && xcodegen           # generates pbxproj + Info.plist from project.yml

# Each build:
./ios/build-xcframework.sh    # rust → xcframework (preflights rustup targets)
# user-side terminal:
! ssh -t neo.local 'security unlock-keychain ~/Library/Keychains/login.keychain-db && \
  export PATH=/opt/homebrew/bin:$PATH && \
  xcodebuild -project ~/ManagedProjects/edge-agent/ios/WeaveIos.xcodeproj \
    -scheme WeaveIos -destination "id=<device-uuid>" -configuration Debug \
    -allowProvisioningUpdates build && \
  xcrun devicectl device install app --device <device-uuid> \
    ~/Library/Developer/Xcode/DerivedData/WeaveIos-*/Build/Products/Debug-iphoneos/WeaveIos.app && \
  xcrun devicectl device process launch --device <device-uuid> com.shin1ohno.weave.WeaveIos'
```

Once `DEVELOPMENT_TEAM` lands in `project.yml`, drop the per-invocation override.

### `CoreDeviceError 3002 / Connection interrupted` is transient

If `xcrun devicectl device install app` fails with `Error Domain=com.apple.dt.CoreDeviceError Code=3002 "Connection interrupted"` (often paired with `IXRemoteErrorDomain Code=6` "Connection with the remote side was unexpectedly closed"), retry the identical command **once** before diagnosing. This is a USB / Wi-Fi handoff transient — the build itself completed (`** BUILD SUCCEEDED **`) and the `.app` bundle is intact; only the wire transfer to the device flaked.

The instinct on first sighting is to suspect codesigning or provisioning. Don't — verify it's transient by re-running the install command first. A second identical-failure means the diagnosis is real and worth a deeper look (device locked, paired-but-not-trusted, etc.).

This rule exists because the 2026-04-29 weave session's first install attempt failed with this exact pair (3002 + IX domain 6); a single retry succeeded with no code change.

## FFI Boundary Error Visibility

`catch` / error branches in iOS code that parses data crossing a UniFFI boundary MUST log at `Logger().error(...)` unconditionally — never gated behind `#if DEBUG`, `WEAVE_DEBUG_BLE=1`, or other compile-/runtime-time switches. Silent FFI parse failures on hardware-only paths cost a full plan → implement → CI → xcframework rebuild → device redeploy cycle per discovery.

The pattern that triggers this: at the FFI boundary, Rust `Result::Err` is converted into a Swift `throw`, and the call site uses `do { try ... } catch { /* silent unless flag set */ }`. The flag-gated logging silences exactly the case where the bug is invisible — on real devices in production-like configs.

Correct shape:

```swift
do {
    if let event = try parseNuimoNotification(charUuid: charUUID, data: data) {
        owner?.record(event, from: identifier)
    }
} catch {
    nuimoLogger.error(
        "parseNuimoNotification failed: char=\(charUUID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
    )
}
```

If the volume is genuinely high, log at `.debug` only the noisy successful-no-match case — never the catch branch. Same applies to `peripheral(_:didUpdateValueFor:error:)` non-nil `error`: log at `.error` so read failures from CoreBluetooth (insufficient permissions, encryption mid-handshake) surface immediately instead of disappearing.

This rule exists because the 2026-04-29 weave session's PR #82 (initial battery read) shipped correctly but battery still didn't appear on hardware — a `WEAVE_DEBUG_BLE=1`-gated catch swallowed the `Uuid::parse_str` failure on Bluetooth-assigned UUIDs (see CoreBluetooth UUID encoding below). The flag-gated diagnostic was set to off in production, so the bug stayed silent through a 40-minute plan-implement-CI-deploy cycle. PR #84 fixed both the encoding and the silent-catch.

## CoreBluetooth UUID encoding — canonical 128-bit form across UniFFI

`CBUUID.uuidString` returns the **short (16- or 32-bit) form** for any UUID inside the Bluetooth Base UUID range:

| UUID | `CBUUID.uuidString` |
|---|---|
| `0x00002A19-0000-1000-8000-00805F9B34FB` (Battery Level) | `"2A19"` |
| `0x0000180F-0000-1000-8000-00805F9B34FB` (Battery Service) | `"180F"` |
| `0xF29B1525-CB19-40F3-BE5C-7241ECB82FD2` (Nuimo custom) | `"F29B1525-CB19-40F3-BE5C-7241ECB82FD2"` |

The short form does NOT round-trip through `uuid::Uuid::parse_str` on the Rust side — it expects a full 128-bit form.

**Rule**: when passing a `CBUUID` to Rust via UniFFI, always use a `canonical128String` helper that pads short-form UUIDs against the Bluetooth Base UUID before serializing. Never call `.uuidString` directly for FFI. Reference implementation in `edge-agent/ios/WeaveIos/Core/NuimoDevice.swift::CBUUID.canonical128String`:

```swift
extension CBUUID {
    var canonical128String: String {
        let bytes = [UInt8](self.data)
        var full: [UInt8] = [
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
            0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB,
        ]
        switch bytes.count {
        case 16: full = bytes
        case 4:
            full[0] = bytes[0]; full[1] = bytes[1]
            full[2] = bytes[2]; full[3] = bytes[3]
        case 2: full[2] = bytes[0]; full[3] = bytes[1]
        default: break
        }
        return String(format: "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                      full[0], full[1], full[2], full[3], full[4], full[5],
                      full[6], full[7], full[8], full[9],
                      full[10], full[11], full[12], full[13], full[14], full[15])
    }
}
```

**Why custom UUIDs masked the bug**: Nuimo input characteristics (button / rotate / touch / fly under `f29b15…`) are outside the Bluetooth Base, so `.uuidString` returns the full 128-bit form and the Rust parser accepted them. Battery is `0x2A19`, inside the Base — short-form serialized, parser rejected, error swallowed. Linux/macOS edge-agent does not hit this because btleplug always hands the parser a full `Uuid` value with no string round-trip.

This applies beyond battery: heart rate (0x2A37), blood pressure (0x2A35), any other Bluetooth-assigned characteristic the iOS app might read in the future. Use `canonical128String`, never `uuidString`, for FFI input.

## Pre-deploy preflight probe — gather environment in one ssh round-trip

Before constructing any iOS build/deploy chain to a remote Mac, run this single probe and read the output. Use the output to construct the actual deploy chain — do NOT ask the user for hostname, UDID, rustup targets, or other machine-queryable values.

```sh
ssh <host>.local 'export PATH=$HOME/.cargo/bin:/opt/homebrew/bin:$PATH; \
  echo "=== hostname ==="; hostname; \
  echo "=== rustup targets ==="; rustup target list --installed 2>/dev/null || echo MISSING; \
  echo "=== devicectl ==="; xcrun devicectl list devices 2>/dev/null; \
  echo "=== toolchain ==="; which xcodegen xcodebuild xcrun cargo 2>&1; \
  echo "=== keychain ==="; security list-keychains -d user 2>&1 | head -2'
```

What the output gives you, with no further user interaction needed:

- **Hostname** — confirms which Mac you reached (catches typos like `neo.local` vs `XMHTM6QVQX.local`)
- **rustup targets installed** — surfaces missing iOS targets BEFORE the chain trips on `error: missing rustup target`. If MISSING is reported, present `! ssh <host>.local 'export PATH=...; rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios'` as a separate one-shot.
- **devicectl device table** — `Name / Hostname / Identifier / State / Model` columns. Read the iPad's `Identifier` directly. **Do NOT write a `--json-output -` jq selector blind** — see `debugging.md` "CLI tool JSON output — probe schema before writing jq". For tabular output, `awk '/iPad/ {print $3}'` is enough; if you must use JSON, run the command once with `--json-output -` and inspect the actual key path before writing the selector.
- **toolchain presence** — `xcodegen` and `xcodebuild` paths confirmed
- **keychain hint** — confirms the user has a login keychain (codesign will need this unlocked at deploy time, see CLI build prerequisites #4)

Probe must come BEFORE any AskUserQuestion about iOS environment. The 2026-04-28 weave session burned 3 round-trips on rustup/PATH/UDID issues that this single probe would have caught at once.

## Auto-resolution table — never ask, always probe

When constructing an iOS deploy command, these "questions" must be self-resolved with the listed probe — never with AskUserQuestion:

| Tempted question | Self-check command |
|---|---|
| Which Mac should I build on? | grep this conversation for `ssh <host>` patterns; or `ssh neo.local hostname && ssh <other>.local hostname` |
| What is the iPad UDID? | `ssh <mac> 'xcrun devicectl list devices'` — read Identifier column |
| Is Xcode installed on `<host>`? | `ssh <host> 'xcode-select -p 2>/dev/null && echo OK'` |
| Are rustup iOS targets installed? | `ssh <host> 'export PATH=$HOME/.cargo/bin:$PATH; rustup target list --installed'` |
| Which device is connected? | `ssh <host> 'xcrun devicectl list devices'` (filter by State=connected if multiple) |
| What's the DEVELOPMENT_TEAM ID? | grep `project.yml` for `DEVELOPMENT_TEAM`, or `security find-identity -v -p codesigning \| grep "Apple Development"` on the Mac |
| Where is the .app bundle? | `xcodebuild -showBuildSettings 2>/dev/null \| awk -F= '/CONFIGURATION_BUILD_DIR/{print $2}'` (already scripted in `ios/deploy.sh`) |

Escalate to AskUserQuestion only when:
- The probe fails (host unreachable, no device matches, multiple ambiguous candidates with no disambiguating context)
- The user has expressed a preference that overrides the probe result
- The choice is genuinely about user intent (e.g., "install on iPhone or iPad — both connected")

## Origin

This rule exists because the 2026-04-26 iOS session walked the four prerequisites one error at a time, costing roughly four extra round-trips before the iPad finally received its first build. The 2026-04-28 weave session compounded this: I asked the user to copy-paste the iPad UDID after a guessed jq selector returned empty, and I AskUserQuestion'd the build host instead of probing. The user explicitly corrected me with "neo.localにsshしてUUIDを取得してください" — codifying that the value should be probed, not asked.
