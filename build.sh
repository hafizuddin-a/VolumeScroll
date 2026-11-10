#!/bin/bash
set -e

APP="VolumeScroll.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

swiftc AppDelegate.swift AudioController.swift SoundPanel.swift main.swift \
    -framework Cocoa \
    -framework CoreAudio \
    -framework ServiceManagement \
    -o "$MACOS/VolumeScroll" \
    -target arm64-apple-macos13.0

# App icon: rendered from make_icon.swift, so no binary assets live in the repo.
ICON_TMP="$(mktemp -d)"
swift make_icon.swift "$ICON_TMP/AppIcon.iconset"
iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$RESOURCES/AppIcon.icns"
rm -rf "$ICON_TMP"

cp Info.plist "$CONTENTS/Info.plist"

echo "✅ Built: VolumeScroll.app"
echo "Run: open VolumeScroll.app"
echo "Feel free to raise issue in github if any trouble!! "
