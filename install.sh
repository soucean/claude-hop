#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "Building release..."
swift build -c release 2>&1 | tail -3

APP_NAME="ClaudeHop"
APP_DIR="dist/${APP_NAME}.app/Contents"
BINARY=".build/arm64-apple-macosx/release/ClaudeHop"

rm -rf "dist/${APP_NAME}.app"
mkdir -p "${APP_DIR}/MacOS" "${APP_DIR}/Resources"

cp "$BINARY" "${APP_DIR}/MacOS/ClaudeHop"

cat > "${APP_DIR}/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ClaudeHop</string>
    <key>CFBundleDisplayName</key>
    <string>ClaudeHop</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.claudehop</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeHop</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

# Copy icon nếu có
if [ -f "../python/src/claude_switcher/resources/icon.png" ]; then
    cp "../python/src/claude_switcher/resources/icon.png" "${APP_DIR}/Resources/"
fi

echo ""
echo "✅ Built: dist/${APP_NAME}.app"
echo ""
echo "Cài vào Applications:"
echo "  cp -r 'dist/${APP_NAME}.app' /Applications/"
echo ""
echo "Chạy ngay:"
echo "  open 'dist/${APP_NAME}.app'"
