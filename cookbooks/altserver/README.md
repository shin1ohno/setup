# AltServer Cookbook

This cookbook installs the necessary macOS applications to enable JIT-enabled UTM on iOS devices via AltStore PAL.

## Background

As of December 2025, Japan now supports alternative app marketplaces on iOS. This enables installing AltStore PAL and JIT-enabled apps like UTM for running virtual machines at full speed.

**Note**: In Japan, only iPhone is supported. iPadOS is not available.

## What This Cookbook Installs

### AltServer

The macOS companion application for AltStore. Required for:
- AltJIT functionality (enabling JIT via Wi-Fi)
- Sideloading apps to iOS devices

### jitterbugpair

A command-line tool from the [Jitterbug project](https://github.com/osy/Jitterbug) that generates device pairing files (`.mobiledevicepairing`) needed for JIT debugging with StikDebug.

## Prerequisites

- macOS with Homebrew installed
- iPhone with iOS 26.2 or later (iPadOS not supported in Japan)
- Japanese Apple ID (for AltStore PAL access in Japan)

## Usage

Include this cookbook in your role:

```ruby
include_cookbook "altserver"
```

Or run directly:

```bash
./bin/mitamae local darwin.rb
```

## iOS Setup Steps

After running this cookbook on your Mac, follow these steps on your iPhone:

### Step 1: Install AltStore PAL

1. Open Safari and go to https://altstore.io/download
2. Tap "Download" and allow the marketplace installation
3. Go to Settings and approve the marketplace
4. Tap "Download" again and "Install App Marketplace"

### Step 2: Install AltStore Classic

1. Open AltStore PAL
2. Go to "Browse" tab
3. Find "AltStore Classic" and tap "GET"

### Step 3: Install UTM

1. In AltStore Classic, go to "Sources" tab
2. Tap "+" and add: `https://alt.getutm.app`
3. Go to "Browse" and install "UTM" (not UTM SE)

### Step 4: Generate Pairing File (on Mac)

1. Connect your iOS device to Mac via USB
2. Unlock your device and trust the Mac if prompted
3. Run in Terminal:
   ```bash
   jitterbugpair
   ```
4. A file named `YOUR-UDID.mobiledevicepairing` will be created
5. Transfer this file to your iOS device via AirDrop

### Step 5: Enable JIT

#### Method A: StikDebug (Recommended - Works Anywhere)

1. Install "StikDebug" from AltStore PAL's recommended sources
2. Open StikDebug and select the pairing file you transferred
3. Allow VPN configuration when prompted
4. In AltStore Classic, go to "My Apps"
5. Long-press UTM and tap "Enable JIT"

#### Method B: AltJIT (Requires Same Wi-Fi as Mac)

1. Start AltServer on your Mac
2. Connect Mac and iOS device to the same Wi-Fi network
3. Open UTM on your iOS device
4. On Mac, click AltServer menu bar icon
5. Select "Enable JIT" > [Your Device] > UTM

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "No valid license provided" error | Update AltStore Classic, re-add UTM repository |
| "Device Not Mounted" error | Force quit StikDebug and restart |
| AltStore PAL won't install | Use Safari only, requires iOS 18.0+ |
| jitterbugpair not found | Run `./bin/mitamae local darwin.rb` again |

## Notes

- JIT must be re-enabled each time UTM is restarted
- StikDebug method works without a Mac after initial pairing setup
- UTM SE (App Store version) does NOT support JIT

## References

- [AltStore](https://altstore.io/)
- [UTM](https://getutm.app/)
- [Jitterbug/jitterbugpair](https://github.com/osy/Jitterbug)
- [AltStore JIT FAQ](https://faq.altstore.io/altstore-classic/enabling-jit)
