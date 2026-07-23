#!/bin/bash
# Build Ink.app and wrap it in a double-clickable .dmg with an Applications
# shortcut, so installing is: open the dmg, drag Ink to Applications.
#
#   ./scripts/make-dmg.sh 1.0.0
set -e
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: ./scripts/make-dmg.sh <version>   e.g. 1.0.0" >&2
  exit 1
fi

CONFIG=release
APP="Ink.app"
DIST="dist"
STAGE="/tmp/ink-dmg-stage"
VOLNAME="Ink"
# Unversioned name so releases/latest/download/Ink.dmg is a permanent link.
DMG="$DIST/Ink.dmg"

# Icon (generated on demand, same as install-ink.sh).
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

echo "▶ assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Ink" "$APP/Contents/MacOS/Ink"
cp Info-Ink.plist "$APP/Contents/Info.plist"
cp Ink.icns "$APP/Contents/Resources/Ink.icns"
mkdir -p "$APP/Contents/Resources/web"
cp -R docs/ "$APP/Contents/Resources/web/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo "▶ staging dmg contents…"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "▶ building dmg…"
rm -rf "$DIST"; mkdir -p "$DIST"
rm -f "$DMG"

# Build writable first so Finder can lay the window out (icon size and
# positions live in the volume's .DS_Store), then compress it.
RW="/tmp/ink-rw.dmg"
rm -f "$RW"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDRW "$RW" >/dev/null
MOUNT="/Volumes/$VOLNAME"
hdiutil attach "$RW" -nobrowse -noautoopen >/dev/null

osascript <<APPLESCRIPT >/dev/null 2>&1 || echo "(window layout skipped)"
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set win to container window
    set current view of win to icon view
    set toolbar visible of win to false
    set statusbar visible of win to false
    -- the sidebar steals width, which is what pushes the icons off-centre
    try
      set sidebar width of win to 0
    end try
    set the bounds of win to {200, 140, 800, 560}
    set opts to the icon view options of win
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    -- re-assert the size: hiding the chrome can resize the window again
    set the bounds of win to {200, 140, 800, 560}
    delay 0.5
    set position of item "Ink.app" of win to {150, 170}
    set position of item "Applications" of win to {450, 170}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT" >/dev/null 2>&1 || hdiutil detach "$MOUNT" -force >/dev/null
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW"
rm -rf "$STAGE" "$APP"

SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
SIZE=$(du -h "$DMG" | cut -f1)
echo
echo "✅ $DMG  ($SIZE)"
echo "   sha256: $SHA"
echo
echo "Next:"
echo "  gh release create v$VERSION $DMG -t \"Ink $VERSION\""
echo "  # then update Casks/ink.rb: version $VERSION, sha256 $SHA"
