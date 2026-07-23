#!/bin/bash
# Build Paint.app, (re)generate the icon if missing, install to /Applications,
# ad-hoc sign, and refresh the icon cache.
set -e
cd "$(dirname "$0")"

# 1) Icon — generate Paint.icns if it isn't there yet.
if [ ! -f Paint.icns ]; then
  echo "▶ generating icon…"
  swiftc scripts/make-icon.swift -o /tmp/paint-make-icon
  /tmp/paint-make-icon /tmp/paint-icon-1024.png
  ICONSET=/tmp/Paint.iconset
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size /tmp/paint-icon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    dbl=$((size*2))
    sips -z $dbl $dbl /tmp/paint-icon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Paint.icns
fi

# 2) Build the .app bundle.
./build-app.sh

# 3) Install to /Applications (fall back to ~/Applications without permission).
DEST=/Applications
if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
echo "▶ installing to $DEST/Paint.app…"
pkill -f "$DEST/Paint.app/Contents/MacOS/Paint" 2>/dev/null || true
rm -rf "$DEST/Paint.app"
cp -R Paint.app "$DEST/"

# 4) Ad-hoc sign and refresh the Finder/Dock icon cache.
codesign --force --deep --sign - "$DEST/Paint.app" 2>/dev/null || true
touch "$DEST/Paint.app"

# 5) Remove the project-local build artifact so only the installed copy exists
#    (otherwise Spotlight/Launchpad shows two "Paint" apps).
rm -rf ./Paint.app

echo "✅ Installed: $DEST/Paint.app"
echo "   Launch with Spotlight (⌘Space → Paint) or: open '$DEST/Paint.app'"
