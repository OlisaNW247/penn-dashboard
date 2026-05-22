#!/usr/bin/env bash
# Builds a shareable PennDashboard.app from the SwiftPM executable target.
# Output: dist/PennDashboard.app and dist/PennDashboard.zip
set -euo pipefail

APP_NAME="PennDashboard"
BUNDLE_ID="com.olisa.PennDashboard"
VERSION="0.1.0"
EXECUTABLE_PRODUCT="penn-dashboard"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Building universal release binary (arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64

# Find the binary — universal builds land under .build/apple/Products/Release
BINARY=""
for candidate in \
  ".build/apple/Products/Release/${EXECUTABLE_PRODUCT}" \
  ".build/release/${EXECUTABLE_PRODUCT}"; do
  if [[ -f "$candidate" ]]; then BINARY="$candidate"; break; fi
done
if [[ -z "$BINARY" ]]; then
  echo "error: could not find built binary" >&2
  exit 1
fi
echo "    binary: $BINARY"

APP_DIR="dist/${APP_NAME}.app"
echo "==> Constructing $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/${APP_NAME}"
chmod +x "$APP_DIR/Contents/MacOS/${APP_NAME}"

echo "==> Generating app icon"
ICONSET="dist/${APP_NAME}.iconset"
ICON_FILE="${APP_NAME}.icns"
swift scripts/make-app-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/$ICON_FILE"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>Penn Dashboard</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIconFile</key><string>${ICON_FILE}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleSignature</key><string>????</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict>
</plist>
EOF

echo "==> Ad-hoc signing (so macOS will actually launch it)"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --verbose=2 "$APP_DIR" || true

echo "==> Packaging dist/${APP_NAME}.zip"
( cd dist && rm -f "${APP_NAME}.zip" && ditto -c -k --sequesterRsrc --keepParent "${APP_NAME}.app" "${APP_NAME}.zip" )

echo ""
echo "Built:      $APP_DIR"
echo "Shareable:  dist/${APP_NAME}.zip"
echo ""
echo "Open locally with:  open $APP_DIR"
