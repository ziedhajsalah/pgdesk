#!/bin/sh
# Builds PGDesk in release mode and wraps it in build/PGDesk.app (ad-hoc signed).
# Usage: scripts/bundle.sh [--open]
set -eu

cd "$(dirname "$0")/.."
swift build -c release --product PGDesk

APP=build/PGDesk.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/PGDesk" "$APP/Contents/MacOS/PGDesk"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.pgdesk.PGDesk</string>
    <key>CFBundleName</key><string>PGDesk</string>
    <key>CFBundleDisplayName</key><string>PGDesk</string>
    <key>CFBundleExecutable</key><string>PGDesk</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--open" ]; then
    open "$APP"
fi
