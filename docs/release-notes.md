## Install

1. Download `Tilefy.zip`, unzip it, and move `Tilefy.app` to `/Applications`.
2. Tilefy isn't notarized, so macOS blocks it at first. Run this once in Terminal:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Tilefy.app
   ```
3. Open Tilefy, and turn it on under System Settings › Privacy & Security › Accessibility.

This build is signed ad-hoc, so after updating you'll need to turn Accessibility off and on again for Tilefy. Building from source with your own Apple Development certificate avoids that. See the [README](https://github.com/sammathew4444/tilefy#install).

## What's new in 0.3.1

- **The focus outline now matches window corners:** it follows each window's real corner radius and curve, instead of a fixed 12pt that left a gap at the corners. For an app that draws its own corners, set `focusBorderRadius` in the config file.
