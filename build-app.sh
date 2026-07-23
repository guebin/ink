#!/bin/bash
# Build Paint.app bundle from the SwiftPM executable (works with Command Line Tools, no Xcode).
set -e
cd "$(dirname "$0")"

CONFIG=release
APP="Paint.app"
BIN=".build/$CONFIG/Paint"

echo "▶ swift build…"
swift build -c "$CONFIG"

echo "▶ assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Paint"
cp Info.plist "$APP/Contents/Info.plist"
[ -f Paint.icns ] && cp Paint.icns "$APP/Contents/Resources/Paint.icns"

# ad-hoc code signature so macOS lets it run locally
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "(codesign skipped)"

echo "✅ Built $APP"
echo "   Run with: open ./$APP   (or: ./$APP/Contents/MacOS/Paint)"
