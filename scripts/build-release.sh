#!/usr/bin/env bash
# Build a Release .app, ad-hoc sign it, and package into a DMG under dist/.
# No Developer ID / notarization: first-run users must right-click → Open.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEME="Notetaker"
CONFIG="Release"
BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
APP_PATH="$BUILD_DIR/Build/Products/$CONFIG/$SCHEME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Notetaker/Resources/Info.plist 2>/dev/null || echo 1.0)"
DMG_PATH="$DIST_DIR/Notetaker-$VERSION.dmg"
STAGE="$(mktemp -d -t notetaker-dmg)"

echo "▸ Clean + build Release…"
rm -rf "$BUILD_DIR"
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  clean build >/dev/null

echo "▸ Ad-hoc sign…"
codesign --force --deep --sign - --options runtime "$APP_PATH"

echo "▸ Stage DMG contents…"
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "▸ Build compressed DMG…"
hdiutil create \
  -volname "Notetaker" \
  -srcfolder "$STAGE" \
  -ov -format UDZO -fs APFS \
  "$DMG_PATH" >/dev/null

rm -rf "$STAGE"

echo
echo "✓ $DMG_PATH"
du -sh "$DMG_PATH"
