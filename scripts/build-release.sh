#!/usr/bin/env bash
# Build a Release .app, sign with the local NotetakerDevCert, and
# package into a DMG under dist/.
#
# Signing strategy:
#   • If `NotetakerDevCert` is in the user's login keychain, sign
#     with it. This matches the cert used during development, so
#     TCC permissions (Accessibility, Microphone) granted to dev
#     builds carry over to the shipped DMG without a re-grant
#     prompt for the same user. Released DMG installations on a
#     FRESH machine still need a one-time grant.
#   • If the cert isn't present (CI builds, fresh checkouts), fall
#     back to ad-hoc signing. First-run users on those builds
#     must right-click → Open and grant permissions normally.
#
# This is NOT Developer ID / notarization. Shipping that requires
# an Apple Developer account ($99/yr) and a notarization workflow
# — see docs/release-notarization.md (TODO) for the upgrade path.
#
# Notarization-ready hooks:
#   • Hardened runtime (`--options runtime`) is preserved in BOTH
#     signing paths so a future Developer ID + xcrun notarytool
#     pass works without re-signing.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SCHEME="Notetaker"
CONFIG="Release"
# Product name is `nox` (set in Xcode project settings), distinct
# from the scheme name `Notetaker`. The .app file Xcode emits
# matches the product name, not the scheme.
PRODUCT_NAME="nox"
BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
APP_PATH="$BUILD_DIR/Build/Products/$CONFIG/$PRODUCT_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Notetaker/Resources/Info.plist 2>/dev/null || echo 1.0)"
# DMG filename uses dots between the product name and the version
# (no hyphens per user direction). This also matches what GitHub
# does to filenames with spaces during release upload, so local
# and uploaded names stay identical and the publish script can
# resolve the asset URL by exact name match.
DMG_PATH="$DIST_DIR/nox.$VERSION.dmg"
STAGE="$(mktemp -d -t notetaker-dmg)"

# Signing identity selection, in priority order:
#   1. Developer ID Application (Apple-issued, notarization-eligible)
#      — proper shipping cert. Use this for any DMG that goes to
#      paying customers / public download.
#   2. NotetakerDevCert (self-signed dev cert) — used during
#      iteration so TCC permissions persist across builds, but
#      not notarization-eligible. Triggers Gatekeeper warnings.
#   3. Ad-hoc ("-") — fallback for fresh checkouts/CI without
#      either cert. Definitely not shippable.
#
# Override via env: BUILD_RELEASE_IDENTITY="..." bash build-release.sh
SIGN_IDENTITY="${BUILD_RELEASE_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')"
    echo "▸ Using Developer ID Application: $SIGN_IDENTITY"
  elif security find-certificate -c NotetakerDevCert ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
    SIGN_IDENTITY="NotetakerDevCert"
    echo "▸ Using dev cert: NotetakerDevCert (NOT notarizable — dev builds only)"
  else
    SIGN_IDENTITY="-"
    echo "▸ No signing cert found — ad-hoc signing (DEFINITELY not shippable)"
  fi
fi

echo "▸ Clean + build Release…"
rm -rf "$BUILD_DIR"
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  clean build >/dev/null

echo "▸ Sign with $SIGN_IDENTITY…"
codesign --force --deep \
  --sign "$SIGN_IDENTITY" \
  --identifier com.aritradebnath.notetaker \
  --options runtime \
  "$APP_PATH"

# Verify the signature so we catch failed signs before shipping a
# broken DMG.
codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null 2>&1 \
  || { echo "✗ codesign verification failed"; exit 1; }

echo "▸ Stage DMG contents…"
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "▸ Build compressed DMG…"
hdiutil create \
  -volname "nox" \
  -srcfolder "$STAGE" \
  -ov -format UDZO -fs APFS \
  "$DMG_PATH" >/dev/null

rm -rf "$STAGE"

echo
echo "✓ $DMG_PATH"
du -sh "$DMG_PATH"
echo
echo "Signed with: $SIGN_IDENTITY"
codesign -dv "$APP_PATH" 2>&1 | grep -E "Identifier|Authority|TeamIdentifier" || true
