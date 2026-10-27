#!/bin/bash
# Builds "CRT Player.app" into ./build.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/CRT Player.app"

swift build -c "$CONFIG" --product CRTPlayer
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CRTPlayer" "$APP/Contents/MacOS/CRTPlayer"
cp Sources/CRTPlayer/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"
