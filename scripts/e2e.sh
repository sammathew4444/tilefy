#!/bin/zsh
# Runs the real-window tests against build/Tilefy.app.
#
# Safe on your own Mac: it quits any running Tilefy and opens its own test windows, and Tilefy only
# manages those during the run. Your other windows aren't moved, though shortcuts are active
# and the test windows take focus, so don't type while it runs (about a minute).
#
# Tilefy needs Accessibility permission. Pass --open to use the permission granted to the app
# (normal for a Mac). Without it, the permission of whatever runs this script applies (for CI).
set -euo pipefail

cd "${0:A:h}/.."
swift build -c release --product TilefyE2E
exec "$(swift build -c release --show-bin-path)/TilefyE2E" "$PWD/build/Tilefy.app" "$@"
