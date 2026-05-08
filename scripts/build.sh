#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="PsyDuck"
BUNDLE_ID="com.gerardc.psyduck"
BUILD_DIR="$ROOT/.build/release"
APP_DIR="$ROOT/dist/${APP_NAME}.app"

# Defaults
VERSION="1.0"
INSTALL=true

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="$2"
            shift 2
            ;;
        --no-install)
            INSTALL=false
            shift
            ;;
        *)
            echo "Unknown flag: $1" >&2
            exit 1
            ;;
    esac
done

echo "Building release binary..."
swift build -c release --package-path "$ROOT"

echo "Creating .app bundle (v${VERSION})..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/gh-prs" "$APP_DIR/Contents/MacOS/gh-prs"
cp "$ROOT/Sources/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
# Copy SPM resource bundle so Bundle.module can find logo.png
cp -r "$BUILD_DIR/gh-prs_gh-prs.bundle" "$APP_DIR/Contents/MacOS/"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>gh-prs</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
PLIST

if [ "$INSTALL" = true ]; then
    echo "Installing to /Applications..."
    rm -rf "/Applications/${APP_NAME}.app"
    cp -r "$APP_DIR" /Applications/
fi

# Create styled DMG for distribution
DMG_PATH="$ROOT/dist/${APP_NAME}.dmg"
DMG_BG="$ROOT/scripts/dmg-background.png"

echo "Creating DMG..."
rm -f "$DMG_PATH"

if command -v create-dmg &>/dev/null; then
    create-dmg \
        --volname "$APP_NAME" \
        --background "$DMG_BG" \
        --window-pos 200 120 \
        --window-size 660 400 \
        --icon-size 128 \
        --icon "$APP_NAME.app" 180 170 \
        --app-drop-link 480 170 \
        --hide-extension "$APP_NAME.app" \
        --no-internet-enable \
        "$DMG_PATH" \
        "$APP_DIR"
else
    echo "  create-dmg not found, falling back to plain hdiutil (brew install create-dmg for styled DMG)"
    DMG_DIR="$ROOT/dist/dmg-staging"
    rm -rf "$DMG_DIR"
    mkdir -p "$DMG_DIR"
    cp -r "$APP_DIR" "$DMG_DIR/"
    ln -s /Applications "$DMG_DIR/Applications"
    hdiutil create -volname "$APP_NAME" \
        -srcfolder "$DMG_DIR" \
        -ov -format UDZO \
        "$DMG_PATH" \
        -quiet
    rm -rf "$DMG_DIR"
fi

echo ""
echo "Done!"
if [ "$INSTALL" = true ]; then
    echo "  Installed:  /Applications/${APP_NAME}.app"
fi
echo "  DMG:        $DMG_PATH"
