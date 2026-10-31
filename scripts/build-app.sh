#!/bin/zsh
# Builds build/Tilefy.app. With --install, also copies it to /Applications and launches it.
set -euo pipefail

cd "${0:A:h}/.."

swift build -c release --product Tilefy

app=build/Tilefy.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Tilefy" "$app/Contents/MacOS/Tilefy"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# macOS ties the Accessibility grant to the signature. A real signing identity keeps the grant
# across rebuilds, while an ad-hoc signature would need re-granting after every build.
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')
if [[ -n "$identity" ]]; then
    echo "Signing with: $identity"
    codesign --force --options runtime --sign "$identity" "$app"
else
    echo "No signing identity found, signing ad-hoc. Accessibility must be re-granted after each rebuild."
    codesign --force --sign - "$app"
fi
codesign --verify --strict "$app"
echo "Built $PWD/$app"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Tilefy && sleep 0.5 || true
    rm -rf /Applications/Tilefy.app
    cp -R "$app" /Applications/Tilefy.app
    open /Applications/Tilefy.app
    echo "Installed and launched /Applications/Tilefy.app"
fi
