# AltServer Cookbook

This cookbook installs the necessary macOS tools to enable JIT-enabled UTM on iOS/iPadOS devices.

## Background

UTM (Universal Turing Machine) is an application that allows you to run virtual machines on iOS/iPadOS. However, to run at full speed, JIT (Just-In-Time) compilation is required, which needs special steps to enable.

### Situation in Japan

- **iPhone**: Alternative app marketplaces (AltStore PAL) available since December 2025
- **iPad**: AltStore PAL is NOT available (EU only). Use TrollStore, SideStore, or AltStore Classic instead

## Performance Comparison

| Mode | Performance | Description |
|------|-------------|-------------|
| **Hypervisor** | 70-90% of native | M1/M2 iPads on iPadOS 16.3 or earlier only |
| **JIT (TCG)** | 8-15% of native | Most common method |
| **UTM SE (no JIT)** | Nearly unusable | DOS or ultra-light Linux only |

> **Important**: Starting with iPadOS 16.4, Apple removed the Hypervisor from the kernel. For newer devices like M4 iPad Pro, JIT is the best performance option available.

## What This Cookbook Installs

### AltServer

The macOS companion application for AltStore:
- AltJIT functionality (enabling JIT via Wi-Fi)
- Sideloading apps to iOS devices

### jitterbugpair

A command-line tool from the [Jitterbug project](https://github.com/osy/Jitterbug) that generates device pairing files (`.mobiledevicepairing`) needed for enabling JIT with SideStore/StikDebug.

## Usage

Include this cookbook in your role:

```ruby
include_cookbook "altserver"
```

Or run directly:

```bash
./bin/mitamae local darwin.rb
```

---

## For iPad: JIT Enablement Methods

Since AltStore PAL is not available for iPad outside the EU, use the following methods.

### Recommended Method by iPadOS Version

| iPadOS Version | Recommended Method | PC Required |
|----------------|-------------------|-------------|
| 14.0–16.6.1, 16.7 RC, 17.0 | **TrollStore** | Initial only |
| 17.1–17.3 | SideStore + SideJITServer | Initial only |
| 17.4–18.x | **SideStore + StikDebug** | Initial only |
| Always have Mac available | AltStore Classic + AltJIT | Every time |

---

### Method 1: TrollStore (Easiest)

**For**: iPadOS 14.0–16.6.1, 16.7 RC, **17.0 only**

**Benefits**:
- Works permanently once installed
- No PC or VPN required
- No signature expiration

**Steps**:

1. Install TrollStore 2 ([Installation Guide](https://ios.cfw.guide/installing-trollstore/))
2. Download [UTM.HV.ipa](https://github.com/utmapp/UTM/releases)
3. Install UTM.HV.ipa via TrollStore
4. Long-press the app → "Open with JIT"

> **Note**: Updating to iPadOS 17.1 or later will make this method unavailable

---

### Method 2: SideStore + StikDebug (No PC Required - Recommended)

**For**: iPadOS 17.4–18.x (except 18.4 β1)

**Benefits**:
- No PC required after initial setup
- Enable JIT on-device

#### Initial Setup (Mac Required)

**Step 1: Generate Pairing File**

```bash
# Connect iPad to Mac via USB
# Tap "Trust This Computer" on iPad

# Run jitterbugpair
jitterbugpair

# Success creates ~/YOUR-UDID.mobiledevicepairing
```

**Step 2: Transfer the File**

```bash
# Compress to zip (prevents extension changes)
cd ~
zip pairing.zip *.mobiledevicepairing
```

Transfer to iPad via AirDrop.

**Step 3: Install SideStore**

1. Install from [SideStore](https://sidestore.io/) official website
2. Enable Settings > Privacy & Security > Developer Mode

**Step 4: Install StikDebug**

1. Open SideStore
2. Add StikDebug source in "Sources" tab
3. Install StikDebug

**Step 5: Import Pairing File**

1. Unzip `pairing.zip` in the Files app
2. Tap the `.mobiledevicepairing` file
3. It will be imported to StikDebug

#### Subsequent Use (No PC Required)

1. Open StikDebug (wait for all LEDs to turn green)
2. Tap "Connect by App"
3. Select UTM
4. When "Attached" appears, launch UTM

> **Note**: After every reboot, you need to open StikDebug to enable JIT

---

### Method 3: AltStore Classic + AltJIT

**For**: iPadOS 14–18.x

**Benefits**:
- Most stable
- Well-documented officially

**Drawbacks**:
- Mac must be on same Wi-Fi every time to enable JIT
- Signature refresh required every 7 days (free Apple ID)

#### Setup

**Step 1: Install AltStore**

1. Launch AltServer on Mac
2. Connect iPad via USB
3. Menu bar AltServer icon > Install AltStore > [Device Name]

**Step 2: Install UTM**

1. Open AltStore on iPad
2. In "Sources" tab, tap `+`
3. Add `https://alt.getutm.app`
4. Install UTM from "Browse"

**Step 3: Generate Pairing File**

```bash
jitterbugpair
```

Transfer the generated file to iPad via AirDrop and import to AltStore.

#### Enable JIT (Every Time)

1. Launch AltServer on Mac
2. Connect Mac and iPad to the same Wi-Fi
3. Open UTM on iPad
4. In AltStore, go to "My Apps" > Long-press UTM > "Enable JIT"

Or from Mac's menu bar:
AltServer icon > Enable JIT > [Device Name] > UTM

---

## For iPhone: AltStore PAL (Available in Japan)

Since December 2025, alternative app marketplaces are available on iPhone in Japan.

### Setup

**Step 1: Install AltStore PAL**

1. Open Safari and go to https://altstore.io/download
2. Tap "Download" and allow the marketplace installation
3. Approve the marketplace in Settings app

**Step 2: Install AltStore Classic**

1. Open AltStore PAL
2. In "Browse" tab, tap "GET" for "AltStore Classic"

**Step 3: Install UTM**

1. In AltStore Classic, "Sources" > `+` > `https://alt.getutm.app`
2. Install UTM from "Browse"

**Step 4: Enable JIT**

Use StikDebug or AltJIT (same methods as described above for iPad).

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| jitterbugpair "No device found" | Use Apple cable, disable Wi-Fi sync |
| Pairing file not found | Check `~/` (home directory) |
| File becomes `.txt` | Compress to zip before transfer |
| Gatekeeper blocks | System Settings > Privacy & Security > "Open Anyway" |
| StikDebug LEDs are red | Check VPN is ON, verify pairing file path |
| "Device Not Mounted" error | Force quit StikDebug and restart |
| JIT doesn't work on iPadOS 18.4 β1 | Apple-side issue. Wait for update or use different version |

---

## Using Hypervisor on M1/M2 iPads

**For**: M1/M2 iPad Pro/Air on iPadOS 15.0–16.3

Starting with iPadOS 16.4, Apple removed the Hypervisor Framework from the kernel. Only M1/M2 iPads that have stayed on 16.3 or earlier can use Hypervisor mode.

**Steps**:
1. Install TrollStore
2. Install UTM.HV.ipa (Hypervisor-enabled build)
3. Launch with "Open with JIT"

In Hypervisor mode, Windows 11 ARM and Linux run at near-native speed.

---

## References

- [AltStore](https://altstore.io/)
- [SideStore](https://sidestore.io/)
- [SideStore JIT Documentation](https://docs.sidestore.io/docs/advanced/jit)
- [TrollStore](https://github.com/opa334/TrollStore)
- [UTM](https://getutm.app/)
- [UTM iOS Installation Guide](https://docs.getutm.app/installation/ios/)
- [Jitterbug/jitterbugpair](https://github.com/osy/Jitterbug)
- [AltStore JIT FAQ](https://faq.altstore.io/altstore-classic/enabling-jit)
