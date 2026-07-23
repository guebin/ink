#!/bin/bash
# Build Ink.app (infinite-canvas board) and install to /Applications.
set -e
cd "$(dirname "$0")"

CONFIG=release
APP="Ink.app"
BIN=".build/$CONFIG/Ink"

# Icon — generate Ink.icns if it isn't there yet.
if [ ! -f Ink.icns ]; then
  echo "▶ generating icon…"
  swiftc scripts/make-ink-icon.swift -o /tmp/ink-make-icon
  /tmp/ink-make-icon /tmp/ink-icon-1024.png
  ICONSET=/tmp/Ink.iconset
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size /tmp/ink-icon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    dbl=$((size*2))
    sips -z $dbl $dbl /tmp/ink-icon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Ink.icns
fi

echo "▶ swift build…"
swift build -c "$CONFIG" --product Ink

echo "▶ assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Ink"
cp Info-Ink.plist "$APP/Contents/Info.plist"
[ -f Ink.icns ] && cp Ink.icns "$APP/Contents/Resources/Ink.icns"
# The board is web code — copy docs/ into the bundle.

mkdir -p "$APP/Contents/Resources/web"
cp -R docs/ "$APP/Contents/Resources/web/"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "(codesign skipped)"

DEST=/Applications
if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
echo "▶ installing to $DEST/Ink.app…"
pkill -f "$DEST/Ink.app/Contents/MacOS/Ink" 2>/dev/null || true
rm -rf "$DEST/Ink.app"
cp -R "$APP" "$DEST/"
codesign --force --deep --sign - "$DEST/Ink.app" 2>/dev/null || true
touch "$DEST/Ink.app"
rm -rf "./$APP"

echo "✅ Installed: $DEST/Ink.app"
echo "   Launch with Spotlight (⌘Space → Ink) or: open '$DEST/Ink.app'"
