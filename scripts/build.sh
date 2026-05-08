#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="PsyDuck"
BUNDLE_ID="com.gerardc.psyduck"
BUILD_DIR="$ROOT/.build/release"
APP_DIR="$ROOT/dist/${APP_NAME}.app"

echo "Building release binary..."
swift build -c release --package-path "$ROOT"

echo "Creating .app bundle..."
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
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
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

echo "Installing to /Applications..."
rm -rf "/Applications/${APP_NAME}.app"
cp -r "$APP_DIR" /Applications/

# Create DMG for distribution
DMG_DIR="$ROOT/dist/dmg-staging"
DMG_PATH="$ROOT/dist/${APP_NAME}.dmg"

echo "Creating DMG..."
rm -rf "$DMG_DIR" "$DMG_PATH"
mkdir -p "$DMG_DIR"
cp -r "$APP_DIR" "$DMG_DIR/"
# Add a symlink to /Applications for drag-to-install
ln -s /Applications "$DMG_DIR/Applications"

hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$DMG_PATH" \
    -quiet

rm -rf "$DMG_DIR"

echo ""
echo "Done!"
echo "  Installed:  /Applications/${APP_NAME}.app"
echo "  DMG:        $DMG_PATH"
