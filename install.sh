#!/bin/bash
set -e

REPO="hafizuddin-a/VolumeScroll"
RAW="https://raw.githubusercontent.com/$REPO/main"
APP_NAME="VolumeScroll.app"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
APP_PATH="$INSTALL_DIR/$APP_NAME"
TMP_DIR=$(mktemp -d)

echo ""
echo "  VolumeScroll Installer"
echo "  ──────────────────────"
echo ""

# Check for Xcode Command Line Tools
if ! command -v swiftc &> /dev/null; then
    echo "  ⚠️  Xcode Command Line Tools not found."
    echo "  Installing... (you may see a system prompt)"
    xcode-select --install
    echo ""
    echo "  Once installed, run this script again."
    exit 1
fi

echo "  ⬇️  Downloading source..."
for FILE in AppDelegate.swift AudioController.swift BluetoothBattery.swift SoundPanel.swift main.swift make_icon.swift Info.plist; do
    curl -fsSL "$RAW/$FILE" -o "$TMP_DIR/$FILE"
done

echo "  🔨 Building..."
cd "$TMP_DIR"
mkdir -p "$APP_NAME/Contents/MacOS" "$APP_NAME/Contents/Resources"

swiftc AppDelegate.swift AudioController.swift BluetoothBattery.swift SoundPanel.swift main.swift \
    -framework Cocoa \
    -framework CoreAudio \
    -framework ServiceManagement \
    -o "$APP_NAME/Contents/MacOS/VolumeScroll" \
    -target arm64-apple-macos13.0

# App icon, drawn at build time
swift make_icon.swift "$TMP_DIR/AppIcon.iconset"
iconutil -c icns "$TMP_DIR/AppIcon.iconset" -o "$APP_NAME/Contents/Resources/AppIcon.icns"

cp Info.plist "$APP_NAME/Contents/Info.plist"

echo "  📦 Installing to $INSTALL_DIR..."
pkill -x VolumeScroll 2>/dev/null || true
rm -rf "$APP_PATH"
cp -r "$APP_NAME" "$INSTALL_DIR/"

echo "  ✅ Done! Launching VolumeScroll..."
echo ""
echo "  👉 First launch: macOS will ask for Accessibility permission."
echo "     Go to System Settings → Privacy & Security → Accessibility"
echo "     and enable VolumeScroll."
echo ""

open "$APP_PATH"
rm -rf "$TMP_DIR"
