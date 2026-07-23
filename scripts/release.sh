#!/bin/bash
# Build Ink.app, zip it for a GitHub Release, and print the sha256 the
# Homebrew cask needs.
#
#   ./scripts/release.sh 1.0.0
#
# Then:
#   gh release create v1.0.0 dist/Ink-1.0.0-macos.zip -t "Ink 1.0.0" -n "..."
#   ...and paste the printed sha256 into the cask.
set -e
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: ./scripts/release.sh <version>   e.g. 1.0.0" >&2
  exit 1
fi

CONFIG=release
APP="Ink.app"
DIST="dist"

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

echo "▶ assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Ink" "$APP/Contents/MacOS/Ink"
cp Info-Ink.plist "$APP/Contents/Info.plist"
cp Ink.icns "$APP/Contents/Resources/Ink.icns"
mkdir -p "$APP/Contents/Resources/web"
cp -R docs/ "$APP/Contents/Resources/web/"

# Stamp the version into the bundle so About/Finder agree with the tag.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

# Ad-hoc signature: not notarized (no Developer ID), but keeps the bundle
# self-consistent so Gatekeeper's complaint is the plain "unidentified
# developer" one rather than "damaged".
codesign --force --deep --sign - "$APP"

echo "▶ zipping…"
rm -rf "$DIST"; mkdir -p "$DIST"
ZIP="$DIST/Ink.zip"
# ditto keeps resource forks / symlinks intact, unlike plain zip
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
rm -rf "$APP"

SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo
echo "✅ $ZIP"
echo "   sha256: $SHA"
echo
echo "Next:"
echo "  gh release create v$VERSION $ZIP -t \"Ink $VERSION\""
echo "  # then update Casks/ink.rb: version $VERSION, sha256 $SHA"
