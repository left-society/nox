#!/usr/bin/env bash
# dev-deploy.sh — build nox, install to /Applications, sign with the
# stable "nox Dev (self-signed)" identity so macOS TCC grants
# (Accessibility, Microphone, etc.) persist across rebuilds.
#
# Without this script the default Xcode build is ad-hoc signed — every
# rebuild produces a different cdhash, macOS treats the new bundle as
# a different app, and the user has to re-grant every permission.
# Signing with the stable self-signed identity fixes that: the code
# requirement matches across builds, so the grant sticks.
#
# Usage:  ./dev-deploy.sh

set -euo pipefail

PROJECT_DIR="/Users/apple/Note taker app"
SCHEME="Notetaker"
CONFIG="Debug"
DERIVED="/Users/apple/Library/Developer/Xcode/DerivedData/Notetaker-gowxswlhngapkudsxxehqkcxsddr/Build/Products/Debug"
APP_NAME="nox.app"
SIGN_IDENTITY="nox Dev (self-signed)"
INSTALL_TARGET="/Applications/${APP_NAME}"

echo "▶ Building ${SCHEME} (${CONFIG})…"
xcodebuild \
  -project "${PROJECT_DIR}/Notetaker.xcodeproj" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIG}" \
  -destination 'platform=macOS' \
  build > /tmp/nox-build.log 2>&1 \
  || { tail -40 /tmp/nox-build.log; exit 1; }
echo "  ✓ build ok"

echo "▶ Quitting any running nox…"
pkill -9 -f "${APP_NAME}/Contents/MacOS/nox" 2>/dev/null || true
sleep 1

echo "▶ Installing to ${INSTALL_TARGET}…"
rm -rf "${INSTALL_TARGET}"
cp -R "${DERIVED}/${APP_NAME}" "${INSTALL_TARGET}"

echo "▶ Signing all nested binaries with stable identity '${SIGN_IDENTITY}'…"
# Order matters: sign leaves first (.dylib, .framework), then the
# main executable, then the bundle wrapper. If we only sign the
# wrapper, dyld refuses to load nested dylibs because their team
# ID doesn't match the main binary ("mapping process and mapped
# file have different Team IDs"). `--deep` alone doesn't always
# re-sign existing nested signatures, so we walk them explicitly.
#
# Each codesign result is logged so we can spot any silent
# Keychain prompt failures (otherwise `set -e` would just kill
# the script with no message).
while IFS= read -r dylib; do
  echo "    sign: $(basename "$dylib")"
  codesign --force --sign "${SIGN_IDENTITY}" "$dylib" || {
    echo "    ✗ failed to sign $dylib"
    exit 1
  }
done < <(find "${INSTALL_TARGET}/Contents" -type f -name "*.dylib" 2>/dev/null)

if [ -d "${INSTALL_TARGET}/Contents/Frameworks" ]; then
  while IFS= read -r fw; do
    echo "    sign: $(basename "$fw")"
    codesign --force --sign "${SIGN_IDENTITY}" "$fw" || true
  done < <(find "${INSTALL_TARGET}/Contents/Frameworks" -type d -name "*.framework" 2>/dev/null)
fi

echo "    sign: nox (main)"
codesign --force --sign "${SIGN_IDENTITY}" "${INSTALL_TARGET}/Contents/MacOS/nox"
echo "    sign: bundle wrapper"
codesign --force --deep --sign "${SIGN_IDENTITY}" "${INSTALL_TARGET}"

echo "▶ Verifying…"
codesign -dv "${INSTALL_TARGET}" 2>&1 | grep -E "Authority|CDHash|Identifier" | head -4

echo "▶ Launching…"
open "${INSTALL_TARGET}"

echo "✓ deployed — TCC grants preserved across this rebuild"
