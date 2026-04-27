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

## Origin

This rule exists because the 2026-04-26 iOS session walked the four prerequisites one error at a time, costing roughly four extra round-trips before the iPad finally received its first build. Codifying them as a single checklist saves that walk on the next fresh Mac.
