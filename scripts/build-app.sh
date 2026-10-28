#!/bin/bash
# Builds "CRT Player.app" into ./build.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/CRT Player.app"

if ! pkg-config --exists mpv; then
    echo "libmpv is required. Install build dependencies with: brew install mpv pkg-config" >&2
    exit 1
fi

swift build -c "$CONFIG" --product CRTPlayer
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CRTPlayer" "$APP/Contents/MacOS/CRTPlayer"
cp Sources/CRTPlayer/Info.plist "$APP/Contents/Info.plist"
cp Resources/Demo.mp4 "$APP/Contents/Resources/Demo.mp4"
/usr/bin/python3 scripts/bundle-libraries.py "$APP"
# Compile the Icon Composer icon into Assets.car (Liquid Glass) plus an .icns fallback.
xcrun actool Resources/AppIcon.icon \
    --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 26.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$(mktemp -d)/partial.plist" \
    --errors --warnings >/dev/null
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"
