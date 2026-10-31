## Install

1. Download `Tilefy.zip`, unzip it, and move `Tilefy.app` to `/Applications`.
2. Tilefy isn't notarized, so macOS blocks it at first. Run this once in Terminal:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Tilefy.app
   ```
3. Open Tilefy, and turn it on under System Settings › Privacy & Security › Accessibility.

This build is signed ad-hoc, so after updating you'll need to turn Accessibility off and on again for Tilefy. Building from source with your own Apple Development certificate avoids that. See the [README](https://github.com/sammathew4444/tilefy#install).

## What's new in 0.3

- **Window groups:** several windows share one tile.
- **Sticky windows:** a floating window that stays with you across workspaces.
- **Remembers your layout:** workspaces, layouts and floats survive restarts and crashes of Tilefy exactly, and each app's windows return to their workspaces after a reboot.
- **Animations:** windows slide to their new places, unless Reduce Motion is on or an app can't keep up.
- **Trackpad swipes:** three or four fingers, moving along the row or between workspaces.
- **Steadier windows:** windows that drift out of place are put back, within limits, and brief glitches in macOS's window list no longer upset focus.
