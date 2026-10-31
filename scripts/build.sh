#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
app="$PWD/build/Easy Display.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/EasyDisplay "$app/Contents/MacOS/EasyDisplay"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$app/Contents/Resources/"; fi
codesign --force --sign - "$app"
printf '\nBuilt: %s\n' "$app"
